#!/usr/bin/env perl
# Run BMO's docker-based test suites and print a colored summary table.

use 5.10.1;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Pod::Usage qw(pod2usage);
use Term::ANSIColor qw(colored);
use Time::HiRes qw(time);

use constant VERSION => '1.1.0';

my $BMO_DIR = $ENV{BMO_DIR} // '.';
my $COMPOSE = ['docker', 'compose', '-f', 'docker-compose.test.yml'];

my %SUITES = (
    sanity => sub {
        my @t = (glob('t/*.t'), glob('extensions/*/t/*.t'));
        return [@$COMPOSE, qw(run --no-deps bmo.test test_sanity), @t];
    },
    bmo => sub {
        my @t = (glob('t/bmo/*.t'), glob('extensions/*/t/bmo/*.t'));
        return [@$COMPOSE, qw(run -e CI=1 bmo.test test_bmo -q -f), @t];
    },
    webservices => sub {
        return [@$COMPOSE, qw(run bmo.test test_webservices)];
    },
    (map {
        my $n = $_;
        ("selenium$n" => sub {
            return [@$COMPOSE, '-e', "SELENIUM_GROUP=$n", 'run', 'bmo.test', 'test_selenium'];
        })
    } 1 .. 4),
);

my @ORDER = qw(sanity bmo webservices selenium1 selenium2 selenium3 selenium4);

my ($build, $list, $help, $usage, $version);
GetOptions(
    'build'   => \$build,
    'list'    => \$list,
    'help'    => \$help,
    'usage'   => \$usage,
    'version' => \$version,
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

if ($build) {
    say colored('==> building test image', 'bold');
    system(@$COMPOSE, 'build') == 0 or die "build failed\n";
}

my @results;
for my $s (@suites) {
    say colored("==> $s", 'bold');
    system(@$COMPOSE, qw(down -v));

    my $cmd = $SUITES{$s}->();
    my $start = time;
    my $rc = system(@$cmd);
    my $dur = time - $start;

    push @results, { name => $s, ok => $rc == 0, dur => $dur };
}

say '';
say colored(sprintf('%-14s %-6s %8s', 'SUITE', 'RESULT', 'TIME'), 'bold');
my $failed = 0;
for my $r (@results) {
    my $status = $r->{ok} ? 'PASS' : 'FAIL';
    my $label  = colored(sprintf('%-6s', $status), $r->{ok} ? 'green' : 'red');
    $failed++ unless $r->{ok};
    printf "%-14s %s %8s\n", $r->{name}, $label, sprintf('%.1fs', $r->{dur});
}

exit($failed ? 1 : 0);

__END__

=head1 NAME

bmo_run_tests.pl - run BMO's docker-based test suites with a colored summary

=head1 SYNOPSIS

bmo_run_tests.pl [--build] [--list] [--help] [--usage] [--version] [suite ...] [dir]

=head1 DESCRIPTION

Runs BMO's docker-compose test suites (sanity, unit, webservices, selenium
x4), one after another, each preceded by C<docker compose down -v>. Prints
a colored PASS/FAIL summary table with per-suite timing at the end. Exits
non-zero if any suite failed.

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

1.1.0

=head1 AUTHOR

Xavier L'Hour

=cut
