#!/usr/bin/perl
package NethackHelperSession;
use strict;
use warnings;
use POE;
use POE::Session;
use base 'POE::Session';
use POE::Component::Client::TCP 1.0042;
use POE::Component::Server::TCP 1.0053;
use POE::Filter::Stream;

use Data::Dumper;
$Data::Dumper::Useqq = 1;

=pod

  use POE;
  use NethackHelperSession;

  new NethackHelperSession({ RemoteServer => 'nethack.alt.org', RemotePort => 23, Port => 1234 } );
  
  POE::Kernel->run();

=cut

# thunk so people don't need to pass 'undef'

sub new { my $class = shift; $class->_new(undef, @_); }

sub _new {
  shift;  # off the class
  my ($session, $options) = @_;
  
  if ($session) {
    # set up slave session to remote server.
    
    # don't sanity check this one, it's only supposed to be internal.

    # No thunks for caller, since the only caller is us.

    return POE::Component::Client::TCP->new( %$options,
        Args => [ $session, $options->{RemoteAddress}, $options->{RemotePort} ],  # undef == we are a listener
        SessionType => __PACKAGE__,
        Started => \&nhsc_started,
    
    #    SessionParams => [ options => {trace => 1, debug => 1} ],

        Filter => 'POE::Filter::Stream',

        Connected => \&nhsc_connected,
        ConnectError => \&nhsc_connect_error,
        Disconnected => \&nhsc_disconnected,

        ServerInput => \&nhsc_recv,
        ServerError => \&nhsc_error,
          
        InlineStates => {
        
          MasterDied => sub { $_[KERNEL]->yield('shutdown'); }, # commit hari-kiri
          
          # don't send if we're shutting down!
          send => sub {
             print ">> remote: ".Dumper($_[ARG0])."\n";
             $_[HEAP]->{shutdown} or $_[HEAP]->{server}->put($_[ARG0]) },
        },
          
        );          
    
  } else {
    # set up main listener
    my $remote_server = delete $options->{RemoteServer} || 'nethack.alt.org';
    my $remote_port = delete $options->{RemotePort} || 23;
    my %thunks;
    exists $options->{$_} and $thunks{$_} = delete $options->{$_}
      # not all of these are meaningful, but I don't want the caller specifying them and subsequently
      # screwing me up.
      # The "Remote*" are posted when the remote connection is connected or dropped.
      for qw(ClientConnected ClientInput ClientDisconnected ClientError ClientFlushed ClientFilter
             ClientInputFilter ClientOutputFilter ClientShutdownOnError Started
             
             RemoteConnected RemoteDisconnected RemoteError
             );

    POE::Component::Server::TCP->new( %$options,
        Alias => 'listener', 
        Args => [ undef, $remote_server, $remote_port, \%thunks, ],  # undef == we are a listener
        SessionType => __PACKAGE__,
        Started => \&nhs_started,
        ClientShutdownOnError => 1,
        ClientConnected => \&nhs_client_connected,
        ClientInput => \&nhs_client_input,
        ClientDisconnected => \&nhs_client_disconnected,
        ClientOutputFilter => 'POE::Filter::Stream',
        ClientInputFilter => 'NethackKeyFilter',
        
        InlineStates => {
          RemoteConnected => \&nhs_remote_connected,
          RemoteDisconnected => \&nhs_remote_disconnected,
          RemoteError => \&nhs_remote_error,
        
          # don't send if we're shutting down!
          send => sub { 
              print "<< local:  ".Dumper($_[ARG0])."\n";
              $_[HEAP]->{shutdown} or $_[HEAP]->{client}->put($_[ARG0]) },
          
          # Emergency stop: If we shutdown for any reason, we need to kill off our slave connection.
          _stop => sub { my ($kernel, $heap) = @_[KERNEL, HEAP];
                          my $peer = $heap->{_peer};
                          $kernel->post($peer, 'MasterDied') if $peer;
                        },
        },

        
        );          
  }
}

use Data::Dumper;

use constant {
    RemoteConnecting => 1,    # Incoming stuff should be buffered.
    RemoteConnected => 2,     # Incoming stuff should be forwarded as normal.
    RemoteDisconnected => 3,  # nothing gets forwarded
  };

# -----------------------------------------------------
#              "Client" (remote connection)   
# -----------------------------------------------------

sub nhsc_started {
  my ($heap, $peer, $ip, $port) = @_[HEAP, ARG0..ARG2];
  $heap->{_peer} = $peer;
  $heap->{remoteip} = $ip;
  $heap->{remoteport} = $port;
  print STDERR "Slave connection started; peer = $peer, ip = $ip, port = $port\n";
}

sub nhsc_connected {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  
  $kernel->post($heap->{_peer}, send => "Connection active.\r\n");
  $kernel->post($heap->{_peer}, 'RemoteConnected');
  sleep 1;
}

sub nhsc_connect_error {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  
  $kernel->post($heap->{_peer}, RemoteError => "Connect ".$heap->{remoteip}.':'.$heap->{remoteport}." error: ".join(', ', @_[ARG0..$#_])."\r\n");
}

sub nhsc_error {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  
  $kernel->post($heap->{_peer}, RemoteError => "Error: ".join(', ', @_[ARG0..$#_])."\r\n");
}

sub nhsc_disconnected {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  
  $kernel->post($heap->{_peer}, 'RemoteDisconnected');
}

sub nhsc_recv {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];

  # $heap->{_peer} should always exist...
  print "**recv remote***\n";
  $kernel->post($heap->{_peer}, send => $data);
}

# -----------------------------------------------------
#              "Server" (local connection)   
# -----------------------------------------------------

my $stupid_fucking_thing;

use Socket;

sub nhs_started {
  my ($heap) = $_[HEAP];
  $heap->{remoteip} = $_[ARG1] or die "Don't have a server to connect to?";
  $heap->{remoteport} = $_[ARG2] or die "Don't have a port to connect to?";
  
  # Let me get this straight.  I want to pass arguments X, Y, and Z to each session that's created by a connecting
  # client.  However, instead, my Started state is only called when the listener session is created, and the arguments
  # are passed to IT.  I never get any Started state for, and can't pass my args to, the connecting client sessions.
  $stupid_fucking_thing = $heap;
  
  my $thunks = $heap->{thunks} = $_[ARG3];
  $thunks->{Started}->(@_) if $thunks->{Started};
  
  my ($port, $ip) = sockaddr_in($heap->{listener}->getsockname);
  print "Listening on port $port\n";
}

sub nhs_client_connected {
  my ($heap, $session) = @_[HEAP, SESSION];

  $heap->{$_} = $stupid_fucking_thing->{$_} for qw/remoteip remoteport thunks/;

  my $thunks = $heap->{thunks};
  print "Client connected!\n";
  
  $heap->{state} = RemoteConnecting;  # connect to remote server.
  $heap->{prebuf} = ''; # buffered input while we're connecting to the other side
  print STDERR "connected: Remote IP=$heap->{remoteip}; port=$heap->{remoteport}\n";
  $heap->{_peer} = NethackHelperSession->_new($session, 
              { RemoteAddress => $heap->{remoteip},
                RemotePort => $heap->{remoteport},
#                Domain => AF_INET,
              });

  # redispatch
  $thunks->{ClientConnected}->(@_) if $thunks->{ClientConnected};
}

sub nhs_client_disconnected {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  my $thunks = $heap->{thunks};
  print "Client disconnected!\n";
  
  # redispatch
  $thunks->{ClientDisconnected}->(@_) if $thunks->{ClientDisconnected};
  
  # kill our peer (and commit suicide, at least for now)
  $kernel->post( $heap->{_peer}, 'shutdown')  if $heap->{_peer};
  $kernel->post( listener => 'shutdown');
}

sub nhs_client_input {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
#  print "Client said something!\n";
  
  if ($heap->{state} == RemoteConnecting) {
    print "Prebuffering\n";
    # we don't have a remote side to talk to yet!
    $heap->{prebuf} .= $data;
  } elsif ($heap->{state} == RemoteConnected) {
    # forward it on
    $kernel->post($heap->{_peer}, send => $data);
  } else {
    print "Dropping\n";
    # We lost our remote side. Just ignore everything.
  }
}

sub nhs_remote_connected {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $heap->{state} = RemoteConnected;
  # if the client sent text to us while we were connecting, send it through now.
  $kernel->post($heap->{_peer}, send => $heap->{prebuf}) if length $heap->{prebuf}; 
  delete $heap->{prebuf};
}

sub nhs_remote_disconnected {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $heap->{state} = RemoteDisconnected;
  delete $heap->{_peer};
  $heap->{client}->put("Remote side closed the connection.\r\n")
    unless $heap->{shutdown};
}
 
sub nhs_remote_error {
  my ($heap, $message) = @_[HEAP, ARG0];
  $heap->{state} = RemoteDisconnected;  # consider it disconnected even if we were Connecting.
  $heap->{client}->put("Error from remote side: $message\r\n")
    unless $heap->{shutdown};
}

package NethackKeyFilter;
use POE::Filter;
use base 'POE::Filter';

# stupid thing
$INC{'NethackKeyFilter.pm'} = __FILE__;

# Translate \e<letter> (how putty sends Alt+<key>) to 0x80|<letter> (how Nethack expects Alt+<key> to be sent)
# Also do some other translation, for e.g. Function keys.

# This is tricky because we have no reliable way of identifying whether an \e is the beginning of an escape sequence,
# or the person actually pressed the Escape key.  We've got to just assume that a lone \e at the end of our buffer
# is a regular keypress.


# http://search.cpan.org/~rcaputo/POE-0.3101/lib/POE/Filter.pm

use constant { TEXT => 0, };

sub new {
  my $class = shift;
  print "Creating new $class filter\n";
  bless [ '' ], $class;
}

sub get {
  my ($this, $in) = @_;
  my $text = join '', @$in;
  # This isn't necessary as we won't be buffering anything.
  #$this->[TEXT] .= $text;
  my @lines = split /(\e.*?[A-Za-z~])/, $text;  # This will split it into escapes and non-escapes.
  print "NethackKeyFilter: input lines = ", join(', ', map "{$_}", @lines), "\n";
  for (@lines) {
    next unless (/^\e/);
    my ($keyname) = (undef);
    
    if ($_ eq "\e") { $keyname = 'Escape'; } # Escape key
    elsif (/^\e([a-z])$/) { $keyname = 'Alt+' . uc($1); $_ = "\x80" | uc($1); } # Alt+<key>
    else { $keyname = "Unknown"; $_ = ''; }
    
    print "Detected $keyname keypress\n";
  }

  @lines = grep length, @lines; # omit lines we blanked out to prevent confusion.
  print "NethackKeyFilter: output lines = ", join(', ', map "{$_}", @lines), "\n";
  return \@lines;
}

#sub put {
#  my ($this, $out) = @_;
#  return $out;
#}

1;