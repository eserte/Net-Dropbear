use strict;
use Test::More;
use File::Temp ();

use Net::Dropbear::SSHd;
use Net::Dropbear::XS;
use IPC::Open3;
use IO::Pty;
use Try::Tiny;

use FindBin;
require "$FindBin::Bin/Helper.pm";

our $port;
our $key_fh;
our $key_filename;
our $sshd;
our $planned;

my $start_str = "ON_START";
my $ok_str    = "IN on_check_pubkey";

$sshd = Net::Dropbear::SSHd->new(
  addrs      => $port,
  noauthpass => 0,
  keys       => $key_filename,
  hooks      => {
    on_log => sub
    {
      shift;
      $sshd->comm->printflush( shift . "\n" );
      return 1;
    },
    on_start => sub
    {
      $sshd->comm->printflush("$start_str\n");
      return 1;
    },
    on_passwd_fill => sub
    {
      return 1;
    },
    on_check_pubkey => sub
    {
      $sshd->comm->printflush("$ok_str\n");
      $_[0] = `cat $FindBin::Bin/test.pub`;
      return 1;
    },
  },
);

$sshd->run;

needed_output(
  {
    $start_str => 'Dropbear started',
  }
);

{
  my %ssh = ssh( key => "$FindBin::Bin/test.key" );
  my $pty = $ssh{pty};

  needed_output(
    {
      $ok_str => 'Got into the passwd hook',
      "Pubkey auth succeeded for '$port' with key" =>
          'Can login with public key auth',
    }
  );

  kill( $ssh{pid} );
  note("SSH output");
  note($_) while <$pty>;
}

{
  my %ssh = ssh( key => "$FindBin::Bin/test_bad.key" );
  my $pty = $ssh{pty};

  needed_output(
    {
      $ok_str => 'Got into the passwd hook',
    }
  );

  needed_output(
    {
      'Permission denied (publickey,password).' =>
          'A unusable key is unusable',
    },
    $pty
  );

  kill( $ssh{pid} );
  note("SSH output");

  note($_) while <$pty>;
}

$sshd->stop;
$sshd->wait;

done_testing($planned);
