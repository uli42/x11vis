# vim:ts=4:sw=4:expandtab
# x11vis - an X11 protocol visualizer
# © 2011 Michael Stapelberg and contributors (see ../LICENSE)
#
package PacketHandler;

use strict;
use warnings;
use Data::Dumper;
use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent;
use Moose;
use JSON::XS;
use IO::Handle;
use Time::HiRes qw(gettimeofday tv_interval);
use Burst;
use lib qw(gen);
use RequestDissector;
use ReplyDissector;
use FileOutput;
use v5.10;

# mapping of X11 IDs to our own IDs
has 'x_ids' => (
    traits => [ 'Hash' ],
    is => 'rw',
    isa => 'HashRef[Str]',
    default => sub { {} },
    handles => {
        add_mapping => 'set',
        id_for_xid => 'get',
        xid_known => 'exists'
    }
);

has 'start_timestamp' => (
    is => 'rw',
    isa => 'ArrayRef',
    default => sub { [ gettimeofday ] },
);

has 'sequence' => (
    traits => [ 'Counter' ],
    is => 'rw',
    isa => 'Int',
    default => 1, # sequence 0 is the x11 connection handshake
    handles => {
        inc_sequence => 'inc',
    }
);

has '_outstanding_replies' => (
    traits => [ 'Hash' ],
    is => 'rw',
    isa => 'HashRef',
    default => sub { {} },
    handles => {
        expect_reply => 'set',
        awaiting_reply => 'exists',
        type_of_reply => 'get',
    }
);

has [ 'child_burst', 'x11_burst' ] => (
    is => 'rw',
    isa => 'Burst',
    default => sub { Burst->new() }
);

sub dump_request {
    my ($self, $data) = @_;
    $data->{type} = 'request';
    $data->{seq} = $self->sequence;
    $data->{elapsed} = tv_interval($self->start_timestamp());
    $self->child_burst->add_packet(encode_json($data));
    $self->expect_reply($self->sequence, $data);
    $self->inc_sequence;
}

sub dump_reply {
    my ($self, $data) = @_;

    $data->{type} = 'reply';
    $data->{elapsed} = tv_interval($self->start_timestamp());
    $self->x11_burst->add_packet(encode_json($data));
}

sub dump_cleverness {
    my ($self, $data) = @_;

    $data->{type} = 'cleverness';
    $data->{elapsed} = tv_interval($self->start_timestamp());
    FileOutput->instance->write(encode_json($data));
}

sub reply_icing {
    my ($self, $data) = @_;

    my $name = $data->{name};
    my %d = %{$data->{moredetails}};

    say "(reply) icing for $name, data = " . Dumper(\%d);
    my $req_data = $self->type_of_reply($data->{seq});

    if ($name eq 'InternAtom') {
        $self->add_mapping($d{atom}, 'atom_' . $d{atom});
        $self->dump_cleverness({
            id => 'atom_' . $d{atom},
            title => $req_data->{moredetails}->{name},
            idtype => 'atom',
            moredetails => {
                name => $req_data->{moredetails}->{name}
            }
        });
        return "%atom_" . $d{atom} . "%";
    }

    if ($name eq 'GetGeometry') {
        return '%' . $d{root} . '% (' . $d{x} . ', ' . $d{y} . ') ' . $d{width} . ' x ' . $d{height};
    }

    if ($name eq 'TranslateCoordinates') {
        return '(' . $d{dst_x} . ', ' . $d{dst_y} . ') on %' . $req_data->{moredetails}->{dst_window} . '%';
    }

    if ($name eq 'GetProperty') {
        if ($d{value} == 0) {
            return 'not set';
        } else {
            return $d{value} . ' (type %atom_' . $d{type} . '%)';
        }
    }

    if ($name eq 'QueryTree') {
        return "(" . (scalar @{$d{children}}) . ' children)';
    }

    undef;
}

sub request_icing {
    my ($self, $data) = @_;

    my $name = $data->{name};
    my %d = %{$data->{moredetails}};

    say "icing for $name";

    # GetInputFocus has no details
    return '' if $name eq 'GetInputFocus';

    # display the ASCII names of atoms and extensions
    return $d{name} if $name eq 'InternAtom';
    return $d{name} if $name eq 'QueryExtension';

    # display translated X11 IDs
    if ($name eq 'GetProperty') {
        my $property = $d{property};
        my $window = $d{window};
        if ($self->xid_known($property)) {
            $property = $self->id_for_xid($property);
        }
        $data->{_references} = [ $property, $window ];
        return "%$property% of %$window%";
    }

    if ($name eq 'GetGeometry') {
        my $drawable = $d{drawable};
        if ($self->xid_known($drawable)) {
            $drawable = $self->id_for_xid($drawable);
        }
        return "%$drawable%";
    }

    if ($name eq 'TranslateCoordinates') {
        my $src = $d{src_window};
        my $dst = $d{dst_window};
        my $src_x = $d{src_x};
        my $src_y = $d{src_y};
        # TODO: translate

        # TODO: better description?
        return "($src_x, $src_y) from %$src% to %$dst%";
    }

    if ($name eq 'QueryTree') {
        my $window = $d{window};
        # TODO: translate

        return "%$window%";
    }

    undef
}

sub handle_request {
    my ($self, $request) = @_;

    my ($opcode) = unpack('c', $request);

    # TODO: id-magie bei GetWindowAttributes

    my $data = RequestDissector::dissect_request($request);
    if (defined($data) && length($data) > 5) {
        # add the icing to the cake
        my $details = $self->request_icing($data);
        $details = '<strong>NOT YET IMPLEMENTED</strong>' unless defined($details);
        $data->{details} = $details;
        $self->dump_request($data);
        return;
    }
    say "Unhandled event with opcode $opcode";
    $self->inc_sequence;
}

sub handle_error {
    my ($self, $error) = @_;
}

sub handle_reply {
    my ($self, $reply) = @_;

    say "Should dump a reply with length ". length($reply);

    my $data = ReplyDissector::dissect_reply($reply, $self);
    if (defined($data) && length($data) > 5) {
        say "data = " . Dumper($data);
        ## add the icing to the cake
        my $details = $self->reply_icing($data);
        $details = '<strong>NOT YET IMPLEMENTED</strong>' unless defined($details);
        $data->{details} = $details;
        $self->dump_reply($data);
        return;
    }
    return;
}

sub handle_event {
    my ($self, $event) = @_;
}

sub client_disconnected {
    my ($self) = @_;

    my $fo = FileOutput->instance;
    my $fh = $fo->output_file;
    print $fh "]";

}

__PACKAGE__->meta->make_immutable;

1
