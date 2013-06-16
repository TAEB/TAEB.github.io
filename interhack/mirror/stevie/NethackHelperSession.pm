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
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use Data::Dumper;
$Data::Dumper::Useqq = 1;

=pod

  use POE;
  use NethackHelperSession;

  new NethackHelperSession({ RemoteServer => 'nethack.alt.org', RemotePort => 23, Port => 1234 } );
  
  POE::Kernel->run();

=cut

sub dumpstr {
        my $tmp = Dumper($_[0]);
        $tmp =~ s/\$VAR1 = //;
        $tmp =~ s/;\s*$//;
        return $tmp;
}

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
			# this gets called when we're sending stuff to the remote side
             #print ">> remote: ".dumpstr($_[ARG0])."\n";
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
        #ClientOutputFilter => 'POE::Filter::Stream',
		ClientFilter => 'NethackFilter',
        
        InlineStates => {
          RemoteConnected => \&nhs_remote_connected,
          RemoteDisconnected => \&nhs_remote_disconnected,
          RemoteError => \&nhs_remote_error,
        
          # don't send if we're shutting down!
          send => sub { 
              #print "<< local:  ".dumpstr($_[ARG0])."\n";
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
  my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];
  
  setsockopt($socket, IPPROTO_TCP, TCP_NODELAY, 1);
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
  #print "**recv remote***\n";
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
  
  # P::C::S::TCP doesn't give me the socket. What the fuck?
  my $socket = $heap->{client}[POE::Wheel::ReadWrite::HANDLE_INPUT];
  print "Socket = $socket\n";
  setsockopt($socket, IPPROTO_TCP, TCP_NODELAY, 1);
  
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
  $kernel->yield('shutdown');	# kill ourselves off.
}
 
sub nhs_remote_error {
  my ($heap, $message) = @_[HEAP, ARG0];
  $heap->{state} = RemoteDisconnected;  # consider it disconnected even if we were Connecting.
  $heap->{client}->put("Error from remote side: $message\r\n")
    unless $heap->{shutdown};
}

package NethackFilter;
use POE::Filter;
use base 'POE::Filter';
use Data::Dumper;
use Term::ANSIColor qw/:constants/;
BEGIN {  *dumpstr = \&NethackHelperSession::dumpstr; }

# stupid thing
$INC{'NethackFilter.pm'} = __FILE__;

# Translate \e<letter> (how putty sends Alt+<key>) to 0x80|<letter> (how Nethack expects Alt+<key> to be sent)
# Also do some other translation, for e.g. Function keys.

# This is tricky because we have no reliable way of identifying whether an \e is the beginning of an escape sequence,
# or the person actually pressed the Escape key.  We've got to just assume that a lone \e at the end of our buffer
# is a regular keypress.

# http://search.cpan.org/~rcaputo/POE-0.3101/lib/POE/Filter.pm

# TEXT = text buffer
# X, Y = cursor X, Y
# W, H = screen width, height
# NETHACKING = set to 1 once we detect that nethack is active.

use constant { TEXT => 0, X => 1, Y => 2, W => 3, H => 4, NETHACKING => 5, }; 

use constant { STATUS_ROW => 23, }; # with first row/column being X=0, Y=0

sub new {
  my $class = shift;
  print "Creating new $class filter\n";
  bless [ '',  -1, -1,  -1, -1, 0, ], $class;
}

use constant { SE => 240, SB => 250, WILL => 251, WONT => 252, DO => 253, DONT => 254, IAC => 255, };
use constant { WindowSize => 31, };

my (@TELNET, @TELNETOPT);
@TELNET[240,250..255] = qw/SE SB WILL WONT DO DONT IAC/;
@TELNETOPT[1, 3, 5, 6, 24, 31, 32, 33, 34, 36] = qw/Echo SuppressGoAhead Status TimingMark TerminalType WindowSize TerminalSpeed RemoteFlowControl LineMode EnvVars/;

sub debug_telnet {
	my $cmd = shift;
	print "IAC ";
	my $opcode = ord substr($cmd, 0, 1, '');
	print $TELNET[$opcode], ' ';
	my $option = ord substr($cmd, 0, 1, '');
	print ($TELNETOPT[$option] || $option);
	print "\n";	
}

sub get {
  my ($this, $in) = @_;
  
  if (!$this->[NETHACKING]) {
	# not in nethack yet, probably still at the dgamelaunch interface
	return [@$in];
  }
	
  my $text = join '', @$in;
  my $tweaked;
=pod
  
  while ($text =~ /\xFF(\xFF|[\xFB-\xFE].|\xFA.*?\xFF\xF0)/g) {
	my $tmp = $1;
	next if $tmp eq "\xFF";	# 0xFF 0xFF => escape for just a 0xFF
	
	print "Telnet data: ", join(' ', map{sprintf '%02x', ord}split//,$tmp), "\n";
	debug_telnet($tmp);
	
	my ($opcode, $option) = unpack('CC', $tmp);
	if ($opcode == SB && $option == WindowSize) {
		my ($w, $h) = unpack('xxnn', $tmp);
		print "Terminal size is ${w}x${h}\n";
		@{$this}[W, H] = ($w, $h);
	}
  }
  pos($text)=0;

=cut

  
  # This isn't necessary as we won't be buffering anything.
  #$this->[TEXT] .= $text;
  my @lines = split /(\e.*?[A-Za-z~])/, $text;  # This will split it into escapes and non-escapes.
  #print "NethackKeyFilter: input lines = ", Dumper(join(', ', map "{$_}", @lines)), "\n";
  for (@lines) {
    next unless (/^\e/);
    my ($keyname) = (undef);
    
    if ($_ eq "\e") { $keyname = 'Escape'; } # Escape key
    elsif (/^\e([a-z])$/) { $keyname = 'Alt+' . uc($1); $tweaked=1; $_ = "\x80" | lc($1); } # Alt+<key>
    else { $keyname = "Unknown"; $tweaked=1; $_ = ''; }
    
    print "Detected $keyname keypress\n";
  }

  if ($tweaked) {
	  @lines = grep length, @lines; # omit lines we blanked out to prevent confusion.
  }
  #print "NethackKeyFilter: output lines = ", Dumper(join(', ', map "{$_}", @lines)), "\n";
  return \@lines;
}


my %ANSI;
# $ANSI{$letter}->($body, $letter)
=pod

ANSI (X3.64) and other DEC escape codes of concern:

ANSI: (ESC [ sequence)

A B C D:	up down left right
H: explicit set cursor position

m: change text attributes (does not affect cursor)
K: erase text (does not affect cursor)
J: erase screen (does not affect cursor)

h: DEC private set mode (used to save screen and cursor position at start)
l: DEC private reset mode (used to restore screen and cursor position at exit)

DEC: (ESC sequence, no [, not terminated by a letter or @)

)<character>: set G1 charset
(<character>: set G0 charset

>: select normal keypad mode

=cut

sub noop { };
sub adjcursor {
	my ($dx, $dy, $this, $text, $letter) = @_;
	my $n;
	$text = substr($text, 2); # strip off the \e[
	if ($text eq '') { $n = 1; }
	else {$n = 0 + $text;}
	$this->[X] += $n * $dx;
	$this->[Y] += $n * $dy;
}
sub warpcursor {
	my ($this, $text, $letter) = @_;
	$text = substr($text, 2); # strip off the \e[
	if ($text eq '') {
		$this->[X] = $this->[Y] = 0;
		return;
	}
	if ($text =~ /(\d+);(\d+)/) {
		$this->[Y] = $1 - 1;
		$this->[X] = $2 - 1;
	} else {
		print "WARNING! can't parse ANSI H sequence data: $text\n";
	}
}

$ANSI{$_} = \&noop for qw/m K J h l/;
$ANSI{A} = sub { adjcursor( 0, -1, @_); };
$ANSI{B} = sub { adjcursor( 0, +1, @_); };
$ANSI{C} = sub { adjcursor(-1,  0, @_); };
$ANSI{D} = sub { adjcursor(+1,  0, @_); };
$ANSI{H} = \&warpcursor;

sub put {
  my ($this, $out) = @_;
  my $text = join '', @$out;
  my $tweaked;
 
  if (!$this->[NETHACKING]) {
	# not in nethack yet, probably still at the dgamelaunch interface
	# Perhaps use "NetHack, Copyright 1985-"  as the trigger?
	if ($text =~ /\e\[\?1047h/ && $text !~ /dgamelaunch/) {
		# 1047h => "use alternate screen buffer"
		print "It looks like they're starting up Nethack now...\n";
		$this->[NETHACKING] = 1;
	}
	return [$text];
  }
  # \cN and \cO aren't displayed, they change the character set in use.
  my @lines = split /([\r\n\cN\cO]|\e[()].|\e>|\e\[[0-9;]*[\@A-Za-z~])/, $text;  # This will split it into escapes and non-escapes.
  #print "NethackANSIFilter: text = ", Dumper(join(', ', map "{$_}", @lines)), "\n";
  for (@lines) {
	next if ($_ eq "\cN" || $_ eq "\cO");
	if ($_ eq "\r") { $this->[X]=0; next; }
	if ($_ eq "\n") { $this->[X]=0; $this->[Y]++; next; }
	if (substr($_, 0, 1) eq "\e") {
		#print "Escape: ", dumpstr($_), "\n";
		# fortunately, the only escapes we're interested in are the ANSI ones
		if (substr($_, 1, 1) eq '[') {
			my $tmp = $_;
			my $letter = chop $tmp;
			if ($ANSI{$letter}) {
				$ANSI{$letter}->($this, $tmp, $letter);
			} else {
				print "WARNING! Unknown ANSI escape '$letter' encountered!\n";
			}
		}
	}
	
	# ordinarily, we'd have to worry about wrapping
	# but Nethack, conveniently enough, doesn't appear to rely on wrapping at all.
	# TODO: here is where we have to check for messages like "Fainting".
	if ($this->[Y] == STATUS_ROW) {
		$tweaked = 1 if s/(\bHungry\b)/BOLD.YELLOW.$1.RESET/e;
		$tweaked = 1 if s/(\bWeak\b)/REVERSE.YELLOW.$1.RESET/e;
		$tweaked = 1 if s/(\bFaint\w+\b)/"\e[30;101m".$1.RESET/e;
	}
	$this->[X] += length;
  }

  if ($tweaked) { return \@lines; }
  return [ $text ];
}

# "Hello Stevie3, welcome to NetHack!  You are a"...
# "Hello Stevie3, the $RACE $CLASS, welcome back to NetHack!"


1;