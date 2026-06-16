#!/usr/bin/env perl
# Backup and restore data from a BMO/Bugzilla instance.
# Covers groups, products (components/versions/milestones), users, and bugs.
# Useful for preserving a dev/test instance across Docker image rebuilds.
#
# Usage:
#   Backup bugs only (by ID):
#     bmo_backup_restore.pl --mode=backup --apikey=KEY --bug=1 --bug=2
#   Backup bugs by product:
#     bmo_backup_restore.pl --mode=backup --apikey=KEY --product="TestProduct"
#   Full instance backup (groups + products + users + all bugs):
#     bmo_backup_restore.pl --mode=backup --apikey=KEY --full
#   Selective backup (structural data only, no bugs):
#     bmo_backup_restore.pl --mode=backup --apikey=KEY --groups --products --users
#   Restore (auto-detects which sections are present):
#     bmo_backup_restore.pl --mode=restore --apikey=KEY --file=backup.json
#
# Notes:
#   - Bug IDs, reporter, and timestamps cannot be preserved (REST API limitation).
#   - A JSON file mapping old bug IDs to new IDs is written alongside the backup.
#   - depends_on/blocks relationships are wired up in a second pass.
#   - Status/resolution is applied via PUT after bug creation.
#   - Restored users receive --restore-password (default: BugRestore123!) as password.
#   - API keys for the authenticated backup user are saved; new values are printed on
#     restore since the original key values cannot be written back via the REST API.
#   - Other users' API keys are not accessible via the REST API.

use 5.10.1;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use JSON::MaybeXS qw(encode_json decode_json JSON);
use LWP::UserAgent;
use HTTP::Request;
use URI::Escape qw(uri_escape);
use POSIX qw(strftime);

use constant VERSION => '1.1.0';

my %opts = (
    url              => 'http://localhost:8000',
    file             => 'bugs_backup.json',
    limit            => 500,
    restore_password => 'BugRestore123!',
);
my @bug_ids;
my @skip_users;

GetOptions(
    'mode=s'             => \$opts{mode},
    'url=s'              => \$opts{url},
    'apikey=s'           => \$opts{apikey},
    'login=s'            => \$opts{login},
    'password=s'         => \$opts{password},
    'file=s'             => \$opts{file},
    'bug=i'              => \@bug_ids,
    'skip-user=s'        => \@skip_users,
    'product=s'          => \$opts{product},
    'limit=i'            => \$opts{limit},
    'full'               => \$opts{full},
    'groups'             => \$opts{include_groups},
    'products'           => \$opts{include_products},
    'users'              => \$opts{include_users},
    'restore-password=s' => \$opts{restore_password},
) or usage();

usage() unless ($opts{mode} // '') =~ /^(backup|restore|deduplicate)$/;

if ($opts{full}) {
    $opts{include_groups}   = 1;
    $opts{include_products} = 1;
    $opts{include_users}    = 1;
}

my $json = JSON->new->utf8->canonical->pretty;
my $ua   = LWP::UserAgent->new(timeout => 120);

my %auth;
if ($opts{apikey}) {
    %auth = (api_key => $opts{apikey});
}
elsif ($opts{login} && $opts{password}) {
    %auth = (login => $opts{login}, password => $opts{password});
}

if    ($opts{mode} eq 'backup')      { do_backup()      }
elsif ($opts{mode} eq 'restore')     { do_restore()     }
else                                  { do_deduplicate() }

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

sub do_backup {
    my $backup = {
        version    => VERSION,
        created_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
        base_url   => $opts{url},
    };

    if ($opts{include_groups}) {
        print "Backing up groups...\n";
        $backup->{groups} = backup_groups();
        printf "  %d group(s).\n", scalar @{$backup->{groups}};
    }

    if ($opts{include_products}) {
        print "Backing up products...\n";
        $backup->{products} = backup_products();
        printf "  %d product(s).\n", scalar @{$backup->{products}};
    }

    if ($opts{include_users}) {
        print "Backing up users...\n";
        $backup->{users} = backup_users();
        printf "  %d user(s).\n", scalar @{$backup->{users}};
    }

    my @ids;
    if (@bug_ids) {
        @ids = @bug_ids;
    }
    elsif ($opts{product}) {
        print "Fetching bug IDs for product '$opts{product}'...\n";
        @ids = get_bug_ids_for_product($opts{product});
    }
    elsif ($opts{full}) {
        print "Fetching all bug IDs...\n";
        @ids = get_all_bug_ids($backup->{products});
    }
    elsif (!$opts{include_groups} && !$opts{include_products} && !$opts{include_users}) {
        die "Specify --bug=ID, --product=NAME, or --full\n";
    }

    if (@ids) {
        printf "Backing up %d bug(s)...\n", scalar @ids;
        $backup->{bugs} = [];
        for my $id (@ids) {
            print "  Bug $id...\n";
            push @{$backup->{bugs}}, backup_bug($id);
        }
    }

    open my $fh, '>', $opts{file} or die "Cannot write $opts{file}: $!\n";
    print $fh $json->encode($backup);
    close $fh;

    printf "Backup saved to %s\n", $opts{file};
}

sub backup_groups {
    # GET /rest/group with no params returns all groups for admins in editgroups.
    my $resp = api_get('group');
    return $resp->{groups} // [];
}

sub backup_products {
    # type=all includes inactive products; fall back to accessible on older instances.
    my $resp = eval { api_get('product', type => 'all') };
    $resp //= api_get('product', type => 'accessible');
    return $resp->{products} // [];
}

sub backup_users {
    my $auth_email = eval { api_get('whoami')->{login} } // $auth{login} // '';

    # 'groups' is intentionally excluded from include_fields here: some Bugzilla
    # versions silently return an empty users list when groups is requested via a
    # match-based search. Group memberships are fetched per-user by ID below.
    my $resp = eval {
        api_get('user',
            match            => '@',
            include_disabled => 1,
            include_fields   => join(',', qw(
                id email real_name can_login email_enabled login_denied_text
            )),
        )
    };
    warn "  Warning: user search failed: $@" if $@;
    my @users = @{($resp // {})->{users} // []};

    # If match=@ returned nothing, retry using the authenticated user's email
    # domain. Covers instances that silently reject a 1-character match string.
    if (!@users && $auth_email =~ /\@(.+)$/) {
        my $domain = $1;
        warn "  Note: '@' search returned no users; retrying with domain '$domain'.\n";
        my $retry = eval {
            api_get('user',
                match            => $domain,
                include_disabled => 1,
                include_fields   => join(',', qw(
                    id email real_name can_login email_enabled login_denied_text
                )),
            )
        };
        if ($@) {
            warn "  Warning: domain search also failed: $@";
        } elsif ($retry) {
            @users = @{$retry->{users} // []};
        }
    }

    warn "  Warning: no users returned — check that your credentials have 'editusers' privilege.\n"
        unless @users;

    if (@skip_users) {
        my %skip = map { lc($_) => 1 } @skip_users;
        @users = grep { !$skip{lc($_->{email} // '')} } @users;
    }

    # Fetch group memberships per user by ID.
    for my $u (@users) {
        my $detail = eval { api_get("user/$u->{id}", include_fields => 'groups') };
        $u->{groups} = $detail->{users}[0]{groups} // []
            if $detail && $detail->{users};
    }

    # API keys are only accessible for the authenticated user.
    if ($auth_email) {
        my $key_resp = eval { api_get('user/api_key') };
        if ($key_resp && @{$key_resp->{api_keys} // []}) {
            for my $u (@users) {
                if (lc($u->{email}) eq lc($auth_email)) {
                    $u->{_api_keys} = $key_resp->{api_keys};
                    printf "  Backed up %d API key(s) for %s.\n",
                        scalar @{$u->{_api_keys}}, $auth_email;
                    last;
                }
            }
        }
    }

    return \@users;
}

sub backup_bug {
    my ($id) = @_;
    my $bug         = api_get("bug/$id")->{bugs}[0];
    my $comments    = api_get("bug/$id/comment")->{bugs}{$id}{comments};
    my $attach_resp = api_get("bug/$id/attachment", include_fields => '_default,data');
    my $attachments = $attach_resp->{bugs}{$id} // [];
    return { %$bug, _comments => $comments, _attachments => $attachments };
}

sub get_bug_ids_for_product {
    my ($product) = @_;
    my $resp = api_get('bug',
        product        => $product,
        limit          => $opts{limit},
        include_fields => 'id',
    );
    return map { $_->{id} } @{$resp->{bugs}};
}

sub get_all_bug_ids {
    my ($products) = @_;
    my @ids;
    if ($products && @$products) {
        for my $p (@$products) {
            my @pids = eval { get_bug_ids_for_product($p->{name}) };
            warn "  Warning: could not fetch bugs for '$p->{name}': $@\n" if $@;
            push @ids, @pids;
        }
    }
    else {
        my $resp = eval { api_get('bug', limit => $opts{limit}, include_fields => 'id') };
        push @ids, map { $_->{id} } @{$resp->{bugs} // []} if $resp;
    }
    return @ids;
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------

sub _check_backup_version {
    my ($backup) = @_;
    my $bv = $backup->{version} // '1.0.0';
    my ($b_maj, $b_min) = (split /\./, $bv)[0, 1];
    my ($c_maj, $c_min) = (split /\./, VERSION)[0, 1];
    die "Backup version $bv is incompatible with this script (v" . VERSION . ").\n"
        if $b_maj > $c_maj;
    warn "Warning: backup version $bv is newer than this script (v" . VERSION
        . "); some data may not be handled correctly.\n"
        if $b_maj == $c_maj && $b_min > $c_min;
}

sub do_restore {
    open my $fh, '<', $opts{file} or die "Cannot read $opts{file}: $!\n";
    my $backup = decode_json(do { local $/; <$fh> });
    close $fh;
    _check_backup_version($backup);

    if ($backup->{groups}) {
        printf "Restoring %d group(s)...\n", scalar @{$backup->{groups}};
        restore_groups($backup->{groups});
    }

    if ($backup->{products}) {
        printf "Restoring %d product(s)...\n", scalar @{$backup->{products}};
        restore_products($backup->{products});
    }

    if ($backup->{users}) {
        printf "Restoring %d user(s)...\n", scalar @{$backup->{users}};
        restore_users($backup->{users});
    }

    if ($backup->{bugs}) {
        my @bugs = @{$backup->{bugs}};
        printf "Restoring %d bug(s)...\n", scalar @bugs;

        my %id_map;

        for my $bug (@bugs) {
            my $old_id = $bug->{id};
            my $existing = eval { api_get("bug/bmo-backup-$old_id", include_fields => 'id') };
            if ($existing && $existing->{bugs} && @{$existing->{bugs}}) {
                my $new_id = $existing->{bugs}[0]{id};
                printf "  Bug %d: already restored as bug %d, skipping.\n",
                    $old_id, $new_id;
                $id_map{$old_id} = $new_id;
                next;
            }
            print "  Bug $old_id: $bug->{summary}\n";
            my $new_id = restore_bug($bug);
            $id_map{$old_id} = $new_id;
            print "    -> created as bug $new_id\n";
        }

        print "Fixing up depends_on/blocks relationships...\n";
        fix_relationships(\@bugs, \%id_map);
    }
}

sub restore_groups {
    my ($groups) = @_;
    for my $g (@$groups) {
        print "  Group: $g->{name}\n";
        eval {
            api_post('group', {
                name        => $g->{name},
                description => $g->{description} // '',
                ($g->{user_regexp} ? (user_regexp => $g->{user_regexp}) : ()),
                is_active   => $g->{is_active} ? JSON->true : JSON->false,
            });
            print "    -> created\n";
        };
        if ($@) {
            if ($@ =~ /group_already_exists|already exists/i) {
                print "    -> already exists, skipped\n";
            }
            else {
                warn "    Warning: $@";
            }
        }
    }
}

sub restore_products {
    my ($products) = @_;
    for my $p (@$products) {
        print "  Product: $p->{name}\n";

        # Use the first active non-default version as the initial version for creation.
        my ($init_ver) = grep { $_->{name} ne 'unspecified' && $_->{is_active} }
                         @{$p->{versions} // []};
        $init_ver //= ($p->{versions} && @{$p->{versions}})
            ? $p->{versions}[0]
            : { name => 'unspecified' };

        my $result = eval {
            api_post('product', {
                name            => $p->{name},
                description     => $p->{description} // '',
                version         => $init_ver->{name},
                is_open         => $p->{is_open}         ? JSON->true : JSON->false,
                has_unconfirmed => $p->{has_unconfirmed} ? JSON->true : JSON->false,
                ($p->{classification} && $p->{classification} ne 'Unclassified'
                    ? (classification => $p->{classification}) : ()),
            });
        };
        if ($@) {
            if ($@ =~ /already exists/i) {
                print "    -> already exists, skipped\n";
            }
            else {
                warn "    Warning: $@";
            }
            next;
        }
        print "    -> created (id $result->{id})\n";

        for my $c (@{$p->{components} // []}) {
            eval {
                api_post('component', {
                    product          => $p->{name},
                    name             => $c->{name},
                    description      => $c->{description} // '',
                    default_assignee => $c->{default_assigned_to} // $c->{default_assignee} // '',
                    ($c->{default_qa_contact}
                        ? (default_qa_contact => $c->{default_qa_contact}) : ()),
                    ($c->{default_cc} && @{$c->{default_cc}}
                        ? (default_cc => $c->{default_cc}) : ()),
                    is_active        => $c->{is_active} ? JSON->true : JSON->false,
                });
                print "      component '$c->{name}' created\n";
            };
            warn "    Warning: component '$c->{name}': $@" if $@;
        }

        for my $v (@{$p->{versions} // []}) {
            next if $v->{name} eq $init_ver->{name};
            eval {
                api_post('version', {
                    product   => $p->{name},
                    name      => $v->{name},
                    is_active => $v->{is_active} ? JSON->true : JSON->false,
                });
                print "      version '$v->{name}' created\n";
            };
            warn "    Warning: version '$v->{name}': $@" if $@;
        }

        for my $m (@{$p->{milestones} // []}) {
            next if $m->{name} eq '---';  # default milestone, auto-created with product
            eval {
                api_post('milestone', {
                    product   => $p->{name},
                    name      => $m->{name},
                    sort_key  => $m->{sort_key} // 0,
                    is_active => $m->{is_active} ? JSON->true : JSON->false,
                });
                print "      milestone '$m->{name}' created\n";
            };
            warn "    Warning: milestone '$m->{name}': $@" if $@;
        }
    }
}

sub restore_users {
    my ($users) = @_;
    for my $u (@$users) {
        print "  User: $u->{email}\n";

        my @group_names = map { ref $_ ? $_->{name} : $_ } @{$u->{groups} // []};

        my $result = eval {
            api_post('user', {
                email     => $u->{email},
                full_name => $u->{real_name} // '',
                password  => $opts{restore_password},
            });
        };
        if ($@) {
            if ($@ =~ /account_already_exists|already exists/i) {
                print "    -> already exists, skipped\n";
            }
            else {
                warn "    Warning: $@";
            }
            next;
        }
        my $new_id = $result->{id};
        print "    -> created (id $new_id)\n";

        if (@group_names) {
            eval { api_put("user/$new_id", { groups => { add => \@group_names } }) };
            warn "    Warning: could not set groups: $@\n" if $@;
        }

        # Disable login if the original account had it disabled.
        if (!$u->{can_login} || ($u->{login_denied_text} // '') ne '') {
            eval {
                api_put("user/$new_id", {
                    login_denied_text => $u->{login_denied_text}
                                     || 'Account disabled (restored from backup)',
                });
            };
            warn "    Warning: could not disable login: $@\n" if $@;
        }

        if (defined $u->{email_enabled} && !$u->{email_enabled}) {
            eval { api_put("user/$new_id", { email_enabled => JSON->false }) };
            warn "    Warning: could not disable email notifications: $@\n" if $@;
        }

        # API key values cannot be written back; create fresh ones and print them.
        for my $k (@{$u->{_api_keys} // []}) {
            next if $k->{revoked};
            eval {
                my $r = api_post('user/api_key', {
                    description => $k->{description} // 'Restored',
                });
                printf "    -> new API key (was: '%s'): %s\n",
                    $k->{description} // '', $r->{api_key} // '(see Bugzilla UI)';
            };
            warn "    Warning: could not create API key: $@\n" if $@;
        }
    }
}

sub restore_bug {
    my ($bug) = @_;

    my @comments    = @{$bug->{_comments}    // []};
    my @attachments = @{$bug->{_attachments} // []};

    my $description = @comments ? shift(@comments)->{text} : '';

    my %create = (
        product     => $bug->{product},
        component   => $bug->{component},
        summary     => $bug->{summary},
        version     => $bug->{version},
        description => $description,
    );

    # Scalar fields — copy only when non-empty.
    # status/resolution excluded: Bugzilla rejects POST with non-open statuses.
    for my $f (qw(
        type severity priority op_sys platform url whiteboard
        assigned_to qa_contact target_milestone deadline
        estimated_time remaining_time
    )) {
        $create{$f} = $bug->{$f}
            if defined $bug->{$f} && $bug->{$f} ne '';
    }

    # Array fields
    $create{keywords} = $bug->{keywords} if $bug->{keywords} && @{$bug->{keywords}};
    $create{cc}       = $bug->{cc}       if $bug->{cc}       && @{$bug->{cc}};

    # Prepend a backup marker alias so future restores can detect this bug without
    # consulting the ID map file. Original aliases are preserved after the marker.
    my @orig_aliases = ref $bug->{alias}   ? @{$bug->{alias}}
                     : $bug->{alias} // '' ? ($bug->{alias})
                     : ();
    $create{alias} = ["bmo-backup-$bug->{id}", @orig_aliases];

    $create{groups} = [map { ref $_ ? $_->{name} : $_ } @{$bug->{groups}}]
        if $bug->{groups} && @{$bug->{groups}};

    # Custom fields (cf_*)
    for my $f (grep { /^cf_/ } keys %$bug) {
        $create{$f} = $bug->{$f}
            if defined $bug->{$f} && $bug->{$f} ne '';
    }

    # Flags on the bug itself
    if ($bug->{flags} && @{$bug->{flags}}) {
        $create{flags} = [
            map {{
                name   => $_->{name},
                status => $_->{status},
                (defined $_->{requestee} ? (requestee => $_->{requestee}) : ()),
            }}
            @{$bug->{flags}}
        ];
    }

    my $result = api_post('bug', \%create);
    my $new_id = $result->{id} or die "Bug creation returned no ID\n";

    # Status/resolution — always applied via PUT; POST rejects non-open statuses.
    my $want_status     = $bug->{status}     // '';
    my $want_resolution = $bug->{resolution} // '';
    if ($want_status ne '' && ($result->{status} // '') ne $want_status) {
        my %update = (status => $want_status);
        $update{resolution} = $want_resolution if $want_resolution ne '';
        eval { api_put("bug/$new_id", \%update) };
        warn "    Warning: could not set status '$want_status': $@\n" if $@;
    }

    for my $comment (@comments) {
        eval {
            api_post("bug/$new_id/comment", {
                comment    => $comment->{text},
                is_private => $comment->{is_private} ? JSON->true : JSON->false,
            });
        };
        warn "    Warning: could not add comment: $@\n" if $@;
    }

    for my $a (@attachments) {
        eval {
            api_post("bug/$new_id/attachment", {
                file_name    => $a->{file_name},
                summary      => $a->{summary},
                content_type => $a->{content_type},
                data         => $a->{data},
                is_patch     => $a->{is_patch}   ? JSON->true : JSON->false,
                is_private   => $a->{is_private} ? JSON->true : JSON->false,
            });
        };
        warn "    Warning: could not add attachment '$a->{file_name}': $@\n" if $@;
    }

    return $new_id;
}

sub fix_relationships {
    my ($bugs, $id_map) = @_;

    for my $bug (@$bugs) {
        my $new_id = $id_map->{ $bug->{id} } or next;

        my @new_depends = grep { defined } map { $id_map->{$_} } @{$bug->{depends_on} // []};
        my @new_blocks  = grep { defined } map { $id_map->{$_} } @{$bug->{blocks}     // []};

        next unless @new_depends || @new_blocks;

        eval {
            api_put("bug/$new_id", {
                (@new_depends ? (depends_on => {set => \@new_depends}) : ()),
                (@new_blocks  ? (blocks     => {set => \@new_blocks } ) : ()),
            });
        };
        warn "  Warning: could not set relationships for bug $new_id: $@\n" if $@;
    }
}

# ---------------------------------------------------------------------------
# Deduplicate
# ---------------------------------------------------------------------------

sub do_deduplicate {
    open my $fh, '<', $opts{file} or die "Cannot read $opts{file}: $!\n";
    my $backup = decode_json(do { local $/; <$fh> });
    close $fh;
    _check_backup_version($backup);

    my @bugs = @{$backup->{bugs} // []};
    printf "Checking %d bug(s) for duplicates...\n", scalar @bugs;

    for my $bug (@bugs) {
        my $old_id = $bug->{id};

        # The canonical restored copy carries the bmo-backup-N alias.
        my $canonical = eval { api_get("bug/bmo-backup-$old_id", include_fields => 'id') };
        unless ($canonical && $canonical->{bugs} && @{$canonical->{bugs}}) {
            printf "  Bug %d: not restored yet, skipping.\n", $old_id;
            next;
        }
        my $canonical_id = $canonical->{bugs}[0]{id};

        # Find the original description (first comment of the backed-up bug).
        my $orig_desc = ($bug->{_comments} && @{$bug->{_comments}})
            ? $bug->{_comments}[0]{text} : '';

        # Search by summary within the same product/component.
        my $matches = eval {
            api_get('bug',
                product        => $bug->{product},
                component      => $bug->{component},
                summary        => $bug->{summary},
                include_fields => 'id,summary,alias',
                limit          => 100,
            )
        };
        next unless $matches && $matches->{bugs};

        my @candidates = grep {
            $_->{id} != $canonical_id
            && $_->{summary} eq $bug->{summary}
            && !grep { $_ eq "bmo-backup-$old_id" } @{$_->{alias} // []}
        } @{$matches->{bugs}};

        # Confirm duplicates by comparing the description.
        my @dups;
        for my $c (@candidates) {
            my $comments = eval {
                api_get("bug/$c->{id}/comment", include_fields => 'text')
            };
            next unless $comments;
            my $desc = $comments->{bugs}{ $c->{id} }{comments}[0]{text} // '';
            push @dups, $c if $desc eq $orig_desc;
        }

        unless (@dups) {
            printf "  Bug %d -> #%d: no duplicates.\n", $old_id, $canonical_id;
            next;
        }

        printf "  Bug %d -> #%d: %d duplicate(s) found.\n",
            $old_id, $canonical_id, scalar @dups;

        for my $dup (@dups) {
            printf "    Removing bug #%d... ", $dup->{id};
            eval { api_delete("bug/$dup->{id}") };
            if ($@) {
                eval {
                    api_put("bug/$dup->{id}", {
                        status     => 'RESOLVED',
                        resolution => 'DUPLICATE',
                        dup_id     => $canonical_id,
                    })
                };
                if ($@) {
                    warn "failed: $@";
                } else {
                    print "marked as RESOLVED DUPLICATE of #$canonical_id.\n";
                }
            } else {
                print "deleted.\n";
            }
        }
    }
}

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

sub api_get {
    my ($path, %params) = @_;
    %params = (%auth, %params);
    my $qs  = join '&', map { uri_escape($_) . '=' . uri_escape($params{$_}) } keys %params;
    my $url = "$opts{url}/rest/$path" . ($qs ? "?$qs" : '');
    my $resp = $ua->get($url, Accept => 'application/json');
    _check($resp, "GET $path");
    return decode_json($resp->decoded_content);
}

sub api_post {
    my ($path, $data) = @_;
    $data = {%auth, %$data};
    my $resp = $ua->post(
        "$opts{url}/rest/$path",
        Content_Type => 'application/json',
        Accept       => 'application/json',
        Content      => encode_json($data),
    );
    _check($resp, "POST $path");
    return decode_json($resp->decoded_content);
}

sub api_put {
    my ($path, $data) = @_;
    $data = {%auth, %$data};
    my $req = HTTP::Request->new(PUT => "$opts{url}/rest/$path");
    $req->header('Content-Type' => 'application/json');
    $req->header('Accept'       => 'application/json');
    $req->content(encode_json($data));
    my $resp = $ua->request($req);
    _check($resp, "PUT $path");
    return decode_json($resp->decoded_content);
}

sub api_delete {
    my ($path) = @_;
    my %params = %auth;
    my $qs  = join '&', map { uri_escape($_) . '=' . uri_escape($params{$_}) } keys %params;
    my $req = HTTP::Request->new(DELETE => "$opts{url}/rest/$path?$qs");
    $req->header('Accept' => 'application/json');
    my $resp = $ua->request($req);
    _check($resp, "DELETE $path");
    return decode_json($resp->decoded_content);
}

sub _check {
    my ($resp, $label) = @_;
    return if $resp->is_success;
    my $body = eval { decode_json($resp->decoded_content) };
    my $msg  = ($body && $body->{message}) ? "$body->{code}: $body->{message}"
                                           : $resp->status_line;
    die "$label failed: $msg\n";
}

# ---------------------------------------------------------------------------

sub usage {
    die <<'END';
Usage: bmo_backup_restore.pl --mode=backup|restore|deduplicate [options]

Options:
  --mode=backup|restore|deduplicate  Required
  --url=URL                Bugzilla base URL  (default: http://localhost:8000)
  --apikey=KEY             API key for authentication
  --login=EMAIL            Login email (alternative to --apikey)
  --password=PASS          Password   (alternative to --apikey)
  --file=FILE              Backup file path   (default: bugs_backup.json)

Backup options:
  --full                   Full instance backup: groups + products + users + all bugs
  --groups                 Include groups
  --products               Include products (components, versions, milestones)
  --users                  Include users and their API keys
  --skip-user=EMAIL        Exclude a user from backup (repeatable)
  --bug=ID                 Specific bug ID to backup (repeatable; combinable with --groups etc.)
  --product=NAME           Backup bugs in this product (combinable with --groups etc.)
  --limit=N                Max bugs per product query (default: 500)

Restore options:
  --restore-password=PASS  Initial password for restored users (default: BugRestore123!)

Restore is automatic: all sections present in the backup file are restored in order
(groups → products → users → bugs).

Deduplicate scans the backup file and, for each bug, deletes any copy that shares
the same summary, product, component, and description but lacks the bmo-backup-N
alias. Deletion requires allowbugdeletion in Bugzilla config; otherwise the
duplicate is marked RESOLVED DUPLICATE.

Examples:
  bmo_backup_restore.pl --mode=backup       --apikey=abc123 --bug=1 --bug=2
  bmo_backup_restore.pl --mode=backup       --apikey=abc123 --product="TestProduct"
  bmo_backup_restore.pl --mode=backup       --apikey=abc123 --full
  bmo_backup_restore.pl --mode=backup       --apikey=abc123 --groups --products --users
  bmo_backup_restore.pl --mode=restore      --apikey=abc123 --file=bugs_backup.json
  bmo_backup_restore.pl --mode=restore      --apikey=abc123 --file=bugs_backup.json \
                        --restore-password="MyDevPass1"
  bmo_backup_restore.pl --mode=deduplicate  --apikey=abc123 --file=bugs_backup.json
END
}
