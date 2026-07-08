#!/usr/bin/env perl
# Run BMO's docker-based test suites and print a colored summary table.

use 5.10.1;
use strict;
use warnings;

use File::Temp qw(tempdir);
use Getopt::Long qw(GetOptions);
use List::Util qw(max);
use POSIX qw(WNOHANG _exit setpgid);
use Pod::Usage qw(pod2usage);
use Term::ANSIColor qw(colored);
use Time::HiRes qw(time);

use constant VERSION => '1.3.1';

my $BMO_DIR = $ENV{BMO_DIR} // '.';
my $remove_orphans;

# $compose is the per-run docker-compose invocation prefix: plain for
# sequential runs, or carrying -p <project> (+ a port-override -f file) so
# parallel suites don't collide on container names, the DB, or host ports.
sub compose_for {
    my (%opt) = @_;
    my @c = ('docker', 'compose', '-f', 'docker-compose.test.yml');
    push @c, '-f', $opt{override} if $opt{override};
    push @c, '-p', $opt{project} if $opt{project};
    return \@c;
}

my %SUITES = (
    sanity => sub {
        my ($compose) = @_;
        my @t = (glob('t/*.t'), glob('extensions/*/t/*.t'));
        return [@$compose, 'run', ($remove_orphans ? '--remove-orphans' : ()), qw(--no-deps bmo.test test_sanity), @t];
    },
    bmo => sub {
        my ($compose) = @_;
        my @t = (glob('t/bmo/*.t'), glob('extensions/*/t/bmo/*.t'));
        return [@$compose, 'run', ($remove_orphans ? '--remove-orphans' : ()), qw(-e CI=1 bmo.test test_bmo -q -f), @t];
    },
    webservices => sub {
        my ($compose) = @_;
        return [@$compose, 'run', ($remove_orphans ? '--remove-orphans' : ()), qw(bmo.test test_webservices)];
    },
    (map {
        my $n = $_;
        ("selenium$n" => sub {
            my ($compose) = @_;
            return [@$compose, 'run', ($remove_orphans ? '--remove-orphans' : ()), '-e', "SELENIUM_GROUP=$n", 'bmo.test', 'test_selenium'];
        })
    } 1 .. 4),
);

my @ORDER = qw(sanity bmo webservices selenium1 selenium2 selenium3 selenium4);

my ($build, $list, $help, $usage, $version);
my $jobs = 1;
GetOptions(
    'build'           => \$build,
    'jobs|j=i'        => \$jobs,
    'list'            => \$list,
    'help'            => \$help,
    'usage'           => \$usage,
    'version'         => \$version,
    'remove-orphans'  => \$remove_orphans,
) or pod2usage(2);
$jobs = 1 if $jobs < 1;

pod2usage(-exitval => 0, -verbose => 1) if $usage;
pod2usage(-exitval => 0, -verbose => 2) if $help;

if ($version) {
    say VERSION;
    exit 0;
}

if ($list) {
    say for @ORDER;
    exit 0;
}

my @args = @ARGV;
$BMO_DIR = pop @args if @args && !$SUITES{$args[-1]};

my @suites = @args ? @args : @ORDER;
for my $s (@suites) {
    die "unknown suite '$s', known: @ORDER\n" unless $SUITES{$s};
}

chdir $BMO_DIR or die "chdir $BMO_DIR: $!\n";
-e 'docker-compose.test.yml' or die "docker-compose.test.yml not found in $BMO_DIR (set BMO_DIR?)\n";

# Every suite's docker output goes to its own log file rather than the
# terminal; the terminal instead shows one continuously redrawn status table
# (SUITE / STATUS / TIME / log path), so logs never interleave.
my $logdir = tempdir(CLEANUP => 0);

if ($build) {
    my $buildlog = "$logdir/build.log";
    say colored('==> building test image', 'bold'), " ($buildlog)";
    system("docker compose -f docker-compose.test.yml build >'$buildlog' 2>&1") == 0
        or die "build failed, see $buildlog\n";
}

my $override;
if ($jobs > 1) {
    # Each parallel suite gets its own compose project (own bmo.db, memcached,
    # etc.) so runs can't stomp on each other's DB state or container names.
    # externalapi.test/bq bind fixed host ports in docker-compose.test.yml, so
    # an override file drops those bindings to let Docker pick free ones.
    $override = "$logdir/port-override.yml";
    open(my $ofh, '>', $override) or die "$override: $!\n";
    # ports: needs the !override tag: Compose concatenates ports: lists
    # across -f files by default, so a plain list here would leave the
    # original fixed host-port binding in place alongside the new one.
    print $ofh <<'YAML';
services:
  externalapi.test:
    ports: !override
      - "8001"
  bq:
    ports: !override
      - "9050"
YAML
    close $ofh;
}

my %status  = map { $_ => 'waiting' } @suites;
my %logpath = map { $_ => "$logdir/$_.log" } @suites;
my %dur;
my %running; # pid => suite name
my @queue = @suites;

END { print "\e[?25h" } # always restore the cursor, even on die/^C

# ASCII only: braille/hourglass glyphs render double-width in some terminal
# fonts while sprintf still counts them as one column, drifting the columns
# after them by one. Plain ASCII has no such ambiguity.
my @SPIN  = ('|', '/', '-', '\\');
my @GLASS = ('.', 'o', 'O', 'o');
my $frame = 0;
my $drawn;

my $w_suite  = max(length('SUITE'), map { length } @suites);
my $w_result = 11;
my $w_time   = max(length('TIME'), 7);
my $w_log    = max(length('LOG'), map { length($logpath{$_}) } @suites);
my @W        = ($w_suite, $w_result, $w_time, $w_log);
my $nlines   = 4 + @suites; # top border, header, separator, one row per suite, bottom border

my $border = sub {
    my ($l, $m, $r) = @_;
    return $l . join($m, map { '─' x ($_ + 2) } @W) . $r;
};
my $top    = $border->('┌', '┬', '┐');
my $midsep = $border->('├', '┼', '┤');
my $bottom = $border->('└', '┴', '┘');

my $draw = sub {
    print "\e[${nlines}A" if $drawn;
    print $top, "\e[K\n";
    print colored(sprintf('│ %-*s │ %-*s │ %*s │ %-*s │', $w_suite, 'SUITE', $w_result, 'STATUS', $w_time, 'TIME', $w_log, 'LOG'), 'bold'), "\e[K\n";
    print $midsep, "\e[K\n";
    for my $s (@suites) {
        my $st = $status{$s};
        my ($result, $t) = ('', '');
        if ($st eq 'waiting') {
            $result = colored(sprintf('%-*s', $w_result, "$GLASS[$frame % @GLASS] WAITING"), 'yellow');
        }
        elsif ($st eq 'running') {
            $result = colored(sprintf('%-*s', $w_result, "$SPIN[$frame % @SPIN] RUNNING"), 'cyan');
        }
        else {
            $result = colored(sprintf('%-*s', $w_result, $st eq 'pass' ? 'PASS' : 'FAIL'), $st eq 'pass' ? 'green' : 'red');
            $t = sprintf('%.1fs', $dur{$s});
        }
        printf "│ %-*s │ %s │ %*s │ %-*s │\e[K\n", $w_suite, $s, $result, $w_time, $t, $w_log, $logpath{$s};
    }
    print $bottom, "\e[K\n";
    $drawn = 1;
};

# Each forked runner gets its own process group (below), so a ^C at the
# terminal does NOT reach it or its docker grandchild automatically; we
# decide what to kill explicitly, once, from here. Otherwise a suite mid
# "down" would swallow the signal and immediately barrel into "run" anyway.
my $interrupted = 0;
$SIG{INT} = $SIG{TERM} = sub {
    _exit(130) if $interrupted; # second ^C: bail out immediately, no cleanup
    $interrupted = 1;
};

my $cleanup_all = sub {
    for my $s (@suites) {
        my $compose = compose_for($jobs > 1 ? (project => "bmo_test_$s", override => $override) : ());
        # `run` containers are one-offs: killing the runner's process group
        # above stops docker-compose itself but not a container it already
        # started, so `kill` (targets the containers directly) has to run
        # before `down -v`, or a killed-mid-test container is left running.
        system(@$compose, 'kill');
        system(@$compose, 'down', '-v', ($remove_orphans ? '--remove-orphans' : ()));
        last if $jobs <= 1; # single shared project, one down is enough
    }
};

print "\n\e[?25l"; # blank line, then hide cursor
while (1) {
    last if $interrupted;
    while (@queue && keys(%running) < $jobs) {
        my $s = shift @queue;
        my $compose  = compose_for($jobs > 1 ? (project => "bmo_test_$s", override => $override) : ());
        my $down_cmd = [@$compose, 'down', '-v', ($remove_orphans ? '--remove-orphans' : ())];
        my $run_cmd  = $SUITES{$s}->($compose);

        my $pid = fork;
        die "fork: $!\n" unless defined $pid;
        if ($pid == 0) {
            setpgid(0, 0); # own group, so it's only ever killed via $running above
            # docker compose still sees an inherited stdin fd pointing at the
            # real tty and, being in a background group now, gets suspended
            # (SIGTTIN/SIGTTOU) the moment it does any tty job-control, even
            # after the containerized test finished. /dev/null sidesteps it.
            open(STDIN, '<', '/dev/null') or die "/dev/null: $!\n";
            open(STDOUT, '>', $logpath{$s}) or die "$logpath{$s}: $!\n";
            open(STDERR, '>&STDOUT') or die "dup STDERR: $!\n";
            say "==> $s";
            system(@$down_cmd);
            my $start = time;
            my $rc = system(@$run_cmd);
            my $sdur = time - $start;
            open(my $rf, '>', "$logdir/$s.result") or die "$!\n";
            print $rf(($rc == 0 ? 1 : 0), "\t", $sdur);
            close $rf;
            _exit(0); # skip END blocks (cursor-restore) meant for the parent
        }
        $running{$pid} = $s;
        $status{$s} = 'running';
    }

    for my $pid (keys %running) {
        next unless waitpid($pid, WNOHANG) == $pid;
        my $s = delete $running{$pid};
        my ($ok, $sdur) = (0, 0);
        if (open(my $rf, '<', "$logdir/$s.result")) {
            ($ok, $sdur) = split /\t/, <$rf>;
            close $rf;
        }
        $status{$s} = $ok ? 'pass' : 'fail';
        $dur{$s} = $sdur;
    }

    $draw->();
    last if !@queue && !%running;
    select(undef, undef, undef, 0.15);
    $frame++;
}

if ($interrupted) {
    say colored('==> stopping running suites and cleaning up...', 'bold');
    kill('TERM', map { -$_ } keys %running) if %running;
    while (%running) {
        for my $pid (keys %running) {
            delete $running{$pid} if waitpid($pid, WNOHANG) == $pid;
        }
        select(undef, undef, undef, 0.1);
    }
    $cleanup_all->();
    print "\e[?25h"; # show cursor
    exit 130;
}

print "\e[?25h"; # show cursor

my $failed = grep { $status{$_} ne 'pass' } @suites;
exit($failed ? 1 : 0);

__END__

=head1 NAME

bmo_run_tests.pl - run BMO's docker-based test suites with a colored summary

=head1 SYNOPSIS

bmo_run_tests.pl [--build] [--jobs N] [--remove-orphans] [--list] [--help] [--usage] [--version] [suite ...] [dir]

=head1 DESCRIPTION

Runs BMO's docker-compose test suites (sanity, unit, webservices, selenium
x4), each preceded by C<docker compose down -v>. Each suite's docker output
goes to its own log file rather than the terminal; the terminal instead
shows a live-updating status table (SUITE / STATUS / TIME / that suite's
log path), with an animated hourglass for suites still queued and an
animated spinner for suites currently running.
Exits non-zero if any suite failed.

With C<--jobs>, up to that many suites run concurrently instead of one at a
time, each under its own compose project (its own DB, memcached, etc.) so
they can't interfere with each other, and with the fixed host ports in
C<docker-compose.test.yml> replaced by Docker-assigned free ones.

C<^C> stops any running and queued suites and cleans up their docker
containers, networks, and volumes before exiting. A second C<^C> exits
immediately without cleaning up.

Run from a bmo checkout, or pass its path as the last argument, or set
C<BMO_DIR> to point at one. If the last argument is not a known suite name,
it is taken as the bmo checkout directory (overriding C<BMO_DIR>).

=head1 SUITES

    sanity       test_sanity over t/*.t extensions/*/t/*.t
    bmo          test_bmo -q -f over t/bmo/*.t extensions/*/t/bmo/*.t (CI=1)
    webservices  test_webservices
    selenium1..4 test_selenium with SELENIUM_GROUP=1..4

With no suite arguments, all suites run in the order above.

=head1 OPTIONS

=over 4

=item --build

Run C<docker compose build> before running the selected suites.

=item --jobs N, -j N

Run up to N suites concurrently, each isolated in its own compose project.
Defaults to 1 (one suite at a time).

=item --remove-orphans

Pass C<--remove-orphans> to every C<docker compose down>/C<run> call, to
clean up containers left behind by services removed or renamed since the
compose file last changed.

=item --list

Print the known suite names, one per line, and exit.

=item --usage

Print a one-line usage summary and exit.

=item --help

Print this full help text and exit.

=item --version

Print the script version and exit.

=back

=head1 ENVIRONMENT

=over 4

=item BMO_DIR

Path to the bmo checkout. Defaults to the current directory. Overridden by
a trailing directory argument on the command line.

=back

=head1 EXIT STATUS

Non-zero if any suite failed, or if C<docker-compose.test.yml> could not be
found under C<BMO_DIR>.

=head1 VERSION

1.3.1

=head1 AUTHOR

Xavier L'Hour

=cut
