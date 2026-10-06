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

use constant VERSION => '2.0.0';

my $BMO_DIR = $ENV{BMO_DIR} // '.';

my @COMPOSE = ('docker', 'compose', '-f', 'docker-compose.test.yml');

my %SUITES = (
    sanity => sub {
        my @t = (glob('t/*.t'), glob('extensions/*/t/*.t'));
        return [@COMPOSE, 'run', qw(--no-deps bmo.test test_sanity), @t];
    },
    bmo => sub {
        my @t = (glob('t/bmo/*.t'), glob('extensions/*/t/bmo/*.t'));
        return [@COMPOSE, 'run', qw(-e CI=1 bmo.test test_bmo -q -f), @t];
    },
    webservices => sub {
        return [@COMPOSE, 'run', qw(bmo.test test_webservices)];
    },
    (map {
        my $n = $_;
        ("selenium$n" => sub {
            return [@COMPOSE, 'run', '-e', "SELENIUM_GROUP=$n", 'bmo.test', 'test_selenium'];
        })
    } 1 .. 4),
);

my @ORDER = qw(sanity bmo webservices selenium1 selenium2 selenium3 selenium4);

my ($build, $list, $help, $usage, $version);
GetOptions(
    'build'           => \$build,
    'list'            => \$list,
    'help'            => \$help,
    'usage'           => \$usage,
    'version'         => \$version,
) or pod2usage(2);

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
    # Each rebuild untags the previous bmo.test/externalapi.test images
    # (~1.5GB apiece) without deleting them; drop those dangling leftovers.
    system("docker image prune -f --filter label=com.docker.compose.project >>'$buildlog' 2>&1");
}

my %status  = map { $_ => 'waiting' } @suites;
my %logpath = map { $_ => "$logdir/$_.log" } @suites;
my %dur;
my ($pid, $cur); # the suite in progress, if any
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

# The forked runner gets its own process group (below), so a ^C at the
# terminal does NOT reach it or its docker grandchild automatically; we
# decide what to kill explicitly, once, from here. Otherwise a suite mid
# "down" would swallow the signal and immediately barrel into "run" anyway.
my $interrupted = 0;
$SIG{INT} = $SIG{TERM} = sub {
    _exit(130) if $interrupted; # second ^C: bail out immediately, no cleanup
    $interrupted = 1;
};

print "\n\e[?25l"; # blank line, then hide cursor
while (1) {
    last if $interrupted;
    if (!$pid && @queue) {
        my $s = shift @queue;
        # --remove-orphans: a `run` one-off container left behind by an
        # interrupted or ad hoc invocation holds onto the same named volumes
        # (mysql-db, data-dir, ...) as the next "fresh" run, leaking DB/schema
        # state across runs (e.g. "Table already exists: bz_schema") until
        # something cleans it.
        my $down_cmd = [@COMPOSE, 'down', '-v', '--remove-orphans'];
        my $run_cmd  = $SUITES{$s}->();

        $pid = fork;
        die "fork: $!\n" unless defined $pid;
        if ($pid == 0) {
            setpgid(0, 0); # own group, so it's only ever killed explicitly on ^C
            # Not the parent's flag-setting handler: on ^C this runner must die
            # right away instead of carrying on into the next step.
            $SIG{INT} = $SIG{TERM} = 'DEFAULT';
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
            # Result is already recorded, so this teardown is not counted in the
            # suite time; without it the stack (and its volumes) stays up.
            system(@$down_cmd);
            _exit(0); # skip END blocks (cursor-restore) meant for the parent
        }
        $cur = $s;
        $status{$s} = 'running';
    }

    if ($pid && waitpid($pid, WNOHANG) == $pid) {
        my $s = $cur;
        undef $pid;
        my ($ok, $sdur) = (0, 0);
        if (open(my $rf, '<', "$logdir/$s.result")) {
            ($ok, $sdur) = split /\t/, <$rf>;
            close $rf;
        }
        $status{$s} = $ok ? 'pass' : 'fail';
        $dur{$s} = $sdur;
    }

    $draw->();
    last if !@queue && !$pid;
    select(undef, undef, undef, 0.15);
    $frame++;
}

if ($interrupted) {
    say colored('==> stopping and cleaning up...', 'bold');
    if ($pid) {
        kill('TERM', -$pid);
        waitpid($pid, 0);
    }
    # `run` containers are one-offs: killing the runner's process group
    # above stops docker-compose itself but not a container it already
    # started, so `kill` (targets the containers directly) has to run
    # before `down -v`, or a killed-mid-test container is left running.
    system(@COMPOSE, 'kill');
    system(@COMPOSE, 'down', '-v', '--remove-orphans');
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

bmo_run_tests.pl [--build] [--list] [--help] [--usage] [--version] [suite ...] [dir]

=head1 DESCRIPTION

Runs BMO's docker-compose test suites (sanity, unit, webservices, selenium
x4), each preceded and followed by C<docker compose down -v --remove-orphans> (leftover
one-off C<run> containers from an earlier interrupted or ad hoc invocation
hold onto the same named volumes as the next "fresh" run, leaking DB/schema
state across runs otherwise). Each suite's docker output
goes to its own log file rather than the terminal; the terminal instead
shows a live-updating status table (SUITE / STATUS / TIME / that suite's
log path), with an animated hourglass for suites still queued and an
animated spinner for the suite currently running.
Exits non-zero if any suite failed.

C<^C> stops the running suite, skips the queued ones, and cleans up the docker
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

Run C<docker compose build> before running the selected suites. Afterwards the
dangling images left behind by earlier compose builds are pruned.

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

2.0.0

=head1 AUTHOR

Xavier L'Hour

=cut
