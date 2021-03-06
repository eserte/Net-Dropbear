use strict;
use Test::More;
use File::Temp ();

use Net::Dropbear::SSHd;
use Net::Dropbear::XS;
use IPC::Open3;
use Try::Tiny;
use IO::Pty;
use IO::Select;

our $planned = 0;
our $port    = int( rand(10000) + 1024 );
our $key_fh  = File::Temp->new( template => "net_dropbear_sshd_XXXXXXXX" );
our $key_filename = $key_fh->filename;
undef $key_fh;

Net::Dropbear::XS::gen_key($key_filename);

END { unlink $key_filename }

our $sshd;

chmod 0500, glob("$FindBin::Bin/test*");

my $last_pty;
$SIG{'CHLD'} = 'IGNORE';

sub needed_output
{
  my $needed = shift;
  my $io     = shift // $sshd->comm;
  my %needed = %$needed;

  my $result = "";

  $planned += keys %needed;

  my %match   = map { $_ => $needed{$_} } grep { $_ !~ m/^!/ } keys %needed;
  my %unmatch = map { $_ => $needed{$_} } grep { $_ =~ m/^!/ } keys %needed;

  my $had_error;

  try
  {
    local $SIG{ALRM} = sub { die; };

    my $s = IO::Select->new();
    $s->add($io);
    $io->blocking(0);

    if ( defined $last_pty && $last_pty->opened )
    {
      $s->add($last_pty);
      $last_pty->blocking(0);
    }

    alarm 4;

SELECT:
    while ( my @fds = $s->can_read )
    {
      foreach my $fd (@fds)
      {
        while ( my $line = $fd->getline )
        {
          my $fileno = $fd->fileno;
          note("#$io#$fileno# $line");

          next
              if $fd ne $io;
          $result .= $line;
          chomp $line;
          foreach my $key ( keys %unmatch )
          {
            my $re = $key;
            $re =~ s/^!//;
            if ( $line =~ m/^ \Q$re\E/xms )
            {
              ok( 0, delete $unmatch{$key} );
              $had_error = 1;
            }
          }
          foreach my $key ( keys %match )
          {
            if ( $line =~ m/^ \Q$key\E/xms )
            {
              ok( 1, delete $match{$key} );
            }
          }
        }

        last SELECT if keys(%match) == 0;
      }

      alarm 4;
    }
    alarm 0;
  }
  catch
  {
    note($_);
  }
  finally
  {
    foreach my $key ( keys %match )
    {
      ok( 0, $match{$key} );
      $had_error = 1;
    }
    foreach my $key ( keys %unmatch )
    {
      ok( 1, $unmatch{$key} );
    }
  };

  if ($had_error)
  {
    diag( "Output Seen: " . join( "\n #\t", split( /\n/, $result ) ) );
  }

  return $result;
}

sub ssh
{
  my %params = @_;

  my $username = $params{username} || $port;
  my $password = $params{password};
  my $key      = $params{key};
  my $cmd      = $params{cmd};

  my @ssh_cmd = (
    'ssh',
    '-oUserKnownHostsFile=/dev/null',
    '-oStrictHostKeyChecking=no',
    $password ? () : ('-oPasswordAuthentication=no'),
    '-oNumberOfPasswordPrompts=1',
    $key ? ( "-i", $key ) : (),
    "-p$port",
    '-T',

    #'-v',
  );

  my $pty     = IO::Pty->new;
  my $ssh_pid = fork;

  if ( !$ssh_pid )
  {
    $pty->make_slave_controlling_terminal();
    my $slave = $pty->slave();
    close $pty;
    open( STDIN,  "<&" . $slave->fileno() );
    open( STDOUT, ">&" . $slave->fileno() );
    open( STDERR, ">&" . $slave->fileno() );

    exec( @ssh_cmd, "$username\@localhost", $cmd ? $cmd : 'false' );
  }

  $pty->close_slave();
  $pty->set_raw();

  if ( defined $password )
  {
    my $buff;
    note("Sending password");
    while ( $pty->sysread( $buff, 1024 ) )
    {
      note("SSH output: $buff");
      if ( $buff =~ m/password:/ )
      {
        $pty->say($password);
        last;
      }
    }
  }

  $last_pty = $pty;
  return (
    pty => $pty,
    pid => $ssh_pid,
  );
}

1;
