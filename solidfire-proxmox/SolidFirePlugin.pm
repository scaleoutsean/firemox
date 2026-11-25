package PVE::Storage::Custom::SolidFirePlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Plugin);

use JSON::XS qw(decode_json encode_json);
use LWP::UserAgent;
use HTTP::Headers;
use HTTP::Request;
use MIME::Base64 ();
use PVE::Tools qw(file_get_contents file_read_firstline file_set_contents run_command);
use PVE::INotify ();
use File::Basename qw(basename dirname);
use Cwd qw(abs_path);
use Time::HiRes qw(usleep);

my $SF_PLUGIN_API     = 17;    # PVE 9.3
my $DEFAULT_PROTOCOL  = 'iscsi';
my $DEFAULT_CHECK_SSL = 0;     # 1 is recommended; set to 0 with snake oil certificates

# -- Storage configuration hooks -------------------------------------------------

sub api {
    my $apiver = PVE::Storage::APIVER();
    return $apiver if $apiver <= $SF_PLUGIN_API;
    return $SF_PLUGIN_API;
}

sub type {
    return 'solidfire';
}

sub plugindata {
    return {
        content => [ { images => 1, none => 1 }, { images => 1 } ],
        format => [ { raw => 1 }, 'raw' ],
        'sensitive-properties' => { password => 1 },
    };
}

sub properties {
    return {
        apiurl     => { description => 'SolidFire JSON-RPC endpoint (e.g. https://cluster/json-rpc/12.5/).', type => 'string' },
        accountid  => { description => 'SolidFire tenant account ID for Proxmox volumes.',                       type => 'integer' },
        vagid      => { description => 'Volume Access Group ID that contains Proxmox initiators.',               type => 'integer', optional => 1 },
        qospolicy  => { description => 'Default QoS policy ID to assign to new volumes (0 = none).',             type => 'integer', optional => 1 },
        check_ssl  => { description => 'Verify SolidFire TLS certificate.',                                      type => 'boolean', default => $DEFAULT_CHECK_SSL },
        protocol   => { description => 'Transport protocol (iscsi only today).',                                 type => 'string', default => $DEFAULT_PROTOCOL },
        'sf-lun-size-gib' => {
            title => 'Provision LUN Size (GiB)',
            description => 'Create a SolidFire LUN named after the storage ID; select content None. This does not create iSCSI or LVM storage.',
            type => 'integer',
            minimum => 1,
            maximum => 16384,
        },
    };
}

sub options {
    return {
        apiurl    => { fixed => 1 },
        username  => { fixed => 1 },
        password  => { optional => 1 },
        accountid => { fixed => 1 },
        vagid     => { optional => 1 },
        qospolicy => { optional => 1 },
        check_ssl => { optional => 1 },
        protocol  => { optional => 1 },
        'sf-lun-size-gib' => { optional => 1, fixed => 1 },
        nodes     => { optional => 1 },
        disable   => { optional => 1 },
        content   => { optional => 1 },
        format    => { optional => 1 },
    };
}

# -- Storage configuration --------------------------------------------------------

sub sf_credentials_path {
    my ($storeid) = @_;
    return "/etc/pve/priv/storage/${storeid}.solidfire.pw";
}

sub on_add_hook {
    my ( $class, $storeid, $scfg, %sensitive ) = @_;
    my $password = $sensitive{password};
    die "SolidFire password is required.\n" unless defined($password) && length($password);

    my $size = $scfg->{'sf-lun-size-gib'};
    if (defined($size)) {
        die "LUN provisioning requires content 'none'; it does not create usable PVE storage.\n"
            unless $scfg->{content}->{none};
    }

    my $path = sf_credentials_path($storeid);
    my $dir = dirname($path);
    mkdir($dir, 0700) or die "Cannot create $dir: $!\n" unless -d $dir;
    die "SolidFire credential file already exists for $storeid.\n" if -e $path;
    file_set_contents($path, $password, 0600);

    return unless defined($size);

    eval {
        die "SolidFire volume '$storeid' already exists for account $scfg->{accountid}.\n"
            if sf_find_volume($scfg, $storeid, $storeid);
        my $result = solidfire_create_volume($scfg, $storeid, $storeid, $size * 1024 * 1024 * 1024);
        die "SolidFire did not return a volume ID for '$storeid'.\n"
            unless defined($result->{volumeID}) || defined($result->{volume}->{volumeID});
    };
    if (my $err = $@) {
        unlink($path) or warn "Cannot remove credential file for $storeid: $!\n";
        die "SolidFire LUN provisioning failed; check the array for '$storeid' before retrying: $err";
    }
}

sub on_update_hook {
    my ( $class, $storeid, $scfg, %sensitive ) = @_;
    return unless exists $sensitive{password};
    my $password = $sensitive{password};
    die "SolidFire password cannot be empty.\n" unless defined($password) && length($password);
    file_set_contents(sf_credentials_path($storeid), $password, 0600);
}

sub on_delete_hook {
    my ( $class, $storeid, $scfg ) = @_;
    my $path = sf_credentials_path($storeid);
    unlink($path) or die "Cannot remove credential file for $storeid: $!\n" if -e $path;
}

# -- Helpers ---------------------------------------------------------------------

my $cmd = {
    multipath  => '/sbin/multipath',
    multipathd => '/sbin/multipathd',
    blockdev   => '/usr/sbin/blockdev'
};

sub exec_command {
    my ( $command, $dm, %param ) = @_;
    $dm //= 1;

    my $fc = $cmd->{ $command->[0] };
    $command->[0] = $fc if defined $fc;

    $param{quiet} = 1 unless $dm < 3 || exists $param{quiet};

    eval { run_command( $command, %param ) };
    if ($@) {
        my $error = " :: Cannot execute '" . join( ' ', @$command ) . "'\n  ==> Error :: $@\n";
        die 'Error' . $error if $dm > 0;
        warn 'Warning' . $error unless $dm < 0;
        return $dm < 0;
    }

    return $dm >= 0;
}

sub scsi_scan_new {
    my ($protocol) = @_;
    my $path = '/sys/class/' . $protocol . '_host';
    opendir( my $dh, $path ) or die "Cannot open directory: $!";
    my @hosts = grep { !/^(\.\.?)$/ } readdir($dh);
    closedir($dh);

    my $count = 0;
    foreach my $host (@hosts) {
        next unless $host =~ /^([\w-]+)$/;
        my $hostdir = '/sys/class/scsi_host/' . $1;
        next unless -d $hostdir;
        device_op( $hostdir, 'scan', '- - -' );
        ++$count;
    }
    die 'Error :: Did not find SCSI hosts to scan.' unless $count > 0;
}

sub multipath_check {
    my ($wwid) = @_;
    my $output = `$cmd->{multipath} -l $wwid`;
    return $output ne '';
}

sub wait_for {
    my ( $success, $message, $timeout, $delay ) = @_;
    $timeout //= 5;
    $delay   //= 0.1;
    my $time = 0;
    while ( $time < $timeout ) {
        return 1 if $success->();
        usleep( $delay * 1_000_000 );
        $time += $delay;
    }
    die "Error :: Timeout while waiting for $message\n";
}

sub device_op {
    my ( $device_path, $op, $value ) = @_;
    open( my $fh, '>', $device_path . '/' . $op ) or die "Error :: Could not open $device_path/$op for writing.\n";
    print $fh $value;
    close $fh;
}

sub get_device_size {
    my ($device) = @_;
    my $path = '/sys/block/' . basename($device) . '/size';
    my $size = file_read_firstline($path) << 9;
    return $size;
}

sub block_device_action {
    my ( $action, @devices ) = @_;
    foreach my $device (@devices) {
        next unless $device =~ /^(sd[a-z]+)$/;
        my $devname = $1;
        my $devpath = '/sys/block/' . $devname . '/device';
        if ( $action eq 'remove' ) {
            exec_command( [ 'blockdev', '--flushbufs', '/dev/' . $devname ] );
            device_op( $devpath, 'state',  'offline' );
            device_op( $devpath, 'delete', '1' );
        } elsif ( $action eq 'rescan' ) {
            device_op( $devpath, 'rescan', '1' );
        } else {
            die "Error :: Unsupported block device action ($action)\n";
        }
    }
}

sub block_device_slaves {
    my ($path) = @_;
    my $device_path = abs_path($path) // '';
    die "Error :: Can't resolve device path for $path\n" unless $device_path =~ /^([\/a-zA-Z0-9_\-.]+)$/;
    $device_path = $1;

    my $device_name = basename($device_path);
    my $slaves_path = '/sys/block/' . $device_name . '/slaves';

    my @slaves;
    if ( -d $slaves_path ) {
        opendir( my $dh, $slaves_path ) or die "Cannot open directory: $!";
        @slaves = grep { !/^(\.\.?)$/ } readdir($dh);
        closedir($dh);
    }
    push @slaves, $device_name unless @slaves;
    return ( $device_path, @slaves );
}

# -- SolidFire API ---------------------------------------------------------------

sub sf_api_request {
    my ( $scfg, $storeid, $method, $params ) = @_;

    my $ua = LWP::UserAgent->new( timeout => 15 );
    if ( !$scfg->{check_ssl} ) {
        $ua->ssl_opts( verify_hostname => 0, SSL_verify_mode => 0x00 );
    }

    my $password = file_get_contents(sf_credentials_path($storeid));
    my $auth = MIME::Base64::encode_base64( $scfg->{username} . ':' . $password, '' );
    my $headers = HTTP::Headers->new(
        'Content-Type'  => 'application/json',
        'Authorization' => 'Basic ' . $auth,
    );

    my $body = encode_json( { method => $method, params => $params // {} } );
    my $request  = HTTP::Request->new( 'POST', $scfg->{apiurl}, $headers, $body );
    my $response = $ua->request($request);

    die "Error :: SolidFire API connection failed ($method): " . $response->status_line . "\n"
        unless $response->is_success;

    my $decoded = decode_json( $response->decoded_content );
    if ( $decoded->{error} ) {
        my $msg = $decoded->{error}->{message} // 'Unknown SolidFire error';
        die "Error :: SolidFire API :: $msg";
    }

    die "Error :: SolidFire API returned no result for $method.\n"
        unless ref($decoded->{result}) eq 'HASH';
    return $decoded->{result};
}

sub sf_list_volumes {
    my ( $scfg, $storeid ) = @_;
    my $volumes = sf_api_request( $scfg, $storeid, 'ListVolumesForAccount', { accountID => int( $scfg->{accountid} ) } )->{volumes};
    die "Error :: SolidFire API returned no volume list.\n" unless ref($volumes) eq 'ARRAY';
    return $volumes;
}

sub sf_find_volume {
    my ( $scfg, $storeid, $volname ) = @_;
    my $vols = sf_list_volumes($scfg, $storeid);
    foreach my $vol (@$vols) {
        next unless $vol->{name} && $vol->{name} eq $volname;
        next if defined $vol->{status} && $vol->{status} eq 'deleted';
        return $vol;
    }
    return undef;
}

sub sf_ensure_volume_in_vag {
    my ( $scfg, $storeid, $volid ) = @_;
    return 1 unless $scfg->{vagid};
    return 1 unless defined $volid;

    my $vag = sf_api_request( $scfg, $storeid, 'ListVolumeAccessGroups', {} );
    my ($group) = grep { $_->{volumeAccessGroupID} == $scfg->{vagid} } @{ $vag->{volumeAccessGroups} // [] };
    return 1 unless $group;    # assume pre-provisioned elsewhere

    my %present = map { $_ => 1 } @{ $group->{volumes} // [] };
    return 1 if $present{$volid};

    sf_api_request( $scfg, $storeid, 'AddVolumesToVolumeAccessGroup', {
        volumeAccessGroupID => int( $scfg->{vagid} ),
        volumes             => [ int($volid) ],
    } );
    return 1;
}

sub sf_get_device_path {
    my ($vol) = @_;
    my $naa = $vol->{scsiNAADeviceID} // '';
    return ( '', '' ) unless $naa;
    my $wwn = lc($naa);
    my $path = '/dev/disk/by-id/wwn-0x' . $wwn;
    return ( $path, $wwn );
}

sub sf_find_snapshot_id {
    my ( $scfg, $storeid, $volume_id, $snapref ) = @_;
    return int($snapref) if defined $snapref && $snapref =~ /^\d+$/;

    my $snaps = sf_api_request( $scfg, $storeid, 'ListSnapshots', { volumeID => int($volume_id) } )->{snapshots} // [];
    foreach my $snap (@$snaps) {
        return $snap->{snapshotID} if $snap->{name} && $snap->{name} eq $snapref;
    }
    die "Error :: Snapshot $snapref not found for volume $volume_id.";
}

# -- Volume helpers --------------------------------------------------------------

sub parse_volname {
    my ( $class, $volname ) = @_;
    if ( $volname =~ m/^(vm|base)-(\d+)-(\S+)$/ ) {
        my $vtype = $1 eq 'vm' ? 'images' : 'base';
        my $vmid  = $2;
        my $name  = $3;
        return ( $vtype, $name, $vmid, undef, undef, undef, 'raw' );
    }
    die "Error :: Invalid volume name ($volname).\n";
}

sub find_free_diskname {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix ) = @_;
    my $volumes   = $class->list_images( $storeid, $scfg, $vmid );
    my @disk_list = map { $_->{name} } @$volumes;
    return PVE::Storage::Plugin::get_next_vm_diskname( \@disk_list, $storeid, $vmid, undef, $scfg );
}

sub solidfire_create_volume {
    my ( $scfg, $storeid, $name, $size_bytes ) = @_;
    my $params = {
        name                   => $name,
        accountID              => int( $scfg->{accountid} ),
        totalSize              => $size_bytes,
        enable512e             => JSON::XS::false,
        associateWithQoSPolicy => JSON::XS::false,
    };
    if ( defined $scfg->{qospolicy} && $scfg->{qospolicy} > 0 ) {
        $params->{qosPolicyID}            = int( $scfg->{qospolicy} );
        $params->{associateWithQoSPolicy} = JSON::XS::true;
    }
    return sf_api_request( $scfg, $storeid, 'CreateVolume', $params );
}

sub solidfire_modify_volume {
    my ( $scfg, $storeid, $volume_id, $body ) = @_;
    my $params = { volumeID => int($volume_id), %$body };
    return sf_api_request( $scfg, $storeid, 'ModifyVolume', $params );
}

sub solidfire_delete_volume {
    my ( $scfg, $storeid, $volume_id ) = @_;
    return sf_api_request( $scfg, $storeid, 'DeleteVolume', { volumeID => int($volume_id) } );
}

# -- Mandatory storage plugin methods -------------------------------------------

sub assert_vm_disk_storage {
    my ($scfg) = @_;
    die "A provisioned SolidFire LUN is not a VM disk datastore.\n"
        if defined $scfg->{'sf-lun-size-gib'};
}

sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;
    assert_vm_disk_storage($scfg);
    die "Error :: Unsupported format ($fmt)." if $fmt ne 'raw';

    if ( defined $name ) {
        die "Error :: Illegal name $name." if $name !~ m/^vm-$vmid-(disk-|cloudinit|state-)/;
    } else {
        $name = $class->find_free_diskname( $storeid, $scfg, $vmid );
    }

    $size = 1024 if $size < 1024;    # at least 1MB
    my $size_bytes = $size * 1024;   # KB to B

    my $result = solidfire_create_volume( $scfg, $storeid, $name, $size_bytes );
    my $volume_id = $result->{volumeID} // $result->{volume}->{volumeID};
    die "Error :: Failed to retrieve SolidFire volume ID for $name." unless defined $volume_id;

    sf_ensure_volume_in_vag( $scfg, $storeid, $volume_id );
    return $name;
}

sub free_image {
    my ( $class, $storeid, $scfg, $volname, $isBase ) = @_;
    assert_vm_disk_storage($scfg);
    my $vol = sf_find_volume( $scfg, $storeid, $volname ) or die "Error :: Volume $volname not found.";
    solidfire_delete_volume( $scfg, $storeid, $vol->{volumeID} );
    return undef;
}

sub list_images {
    my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;
    return [] if defined $scfg->{'sf-lun-size-gib'};
    $vmid = '*' unless defined $vmid;
    my $names = "vm-$vmid-disk-*,vm-$vmid-cloudinit,vm-$vmid-state-*";

    my $vols = sf_list_volumes($scfg, $storeid);
    my @items;
    foreach my $vol (@$vols) {
        my $name = $vol->{name} // next;
        next if $vol->{status} && $vol->{status} eq 'deleted';
        next unless $name =~ /^(vm|base)-(\d+)-(\S+)$/;
        next if $vollist && !grep { $_ eq $name } @$vollist;

        my ( undef, undef, $vm ) = $class->parse_volname($name);
        my $ctime = int( ($vol->{createTime} // 0) / 1000 );
        push @items, {
            name   => $name,
            vmid   => $vm,
            size   => $vol->{totalSize} // 0,
            used   => $vol->{totalSize} // 0,
            ctime  => $ctime,
            volid  => $storeid ? "$storeid:$name" : $name,
            format => 'raw'
        };
    }
    return \@items;
}

sub status {
    my ( $class, $storeid, $scfg, $cache ) = @_;
    my $capacity = sf_api_request( $scfg, $storeid, 'GetClusterCapacity', {} );
    my $total = $capacity->{maxOverProvisionableSpace} // $capacity->{maxUsedSpace} // 0;
    my $used  = $capacity->{usedSpace} // 0;
    my $free  = $total - $used;
    $free = 0 if $free < 0;
    return ( $total, $free, $used, 1 );
}

sub activate_storage {
    return 1;
}

sub deactivate_storage {
    return 1;
}

sub volume_size_info {
    my ( $class, $scfg, $storeid, $volname, $timeout ) = @_;
    assert_vm_disk_storage($scfg);
    my $vol = sf_find_volume( $scfg, $storeid, $volname ) or die "Error :: Volume $volname not found.";
    my $size = $vol->{totalSize} // 0;
    return wantarray ? ( $size, 'raw', $size, undef ) : $size;
}

# -- Device mapping --------------------------------------------------------------

sub map_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname ) = @_;
    assert_vm_disk_storage($scfg);
    my $vol = sf_find_volume( $scfg, $storeid, $volname ) or die "Error :: Volume $volname not found.";
    sf_ensure_volume_in_vag( $scfg, $storeid, $vol->{volumeID} );

    my ( $path, $wwid ) = sf_get_device_path($vol);
    die "Error :: Missing NAA/WWN for $volname." unless $path;

    my $protocol = $scfg->{protocol} // $DEFAULT_PROTOCOL;
    die "Error :: Protocol $protocol not supported." unless $protocol eq 'iscsi';

    scsi_scan_new($protocol);

    my $path_exists = sub { return -e $path; };
    wait_for( $path_exists, "volume $volname to map", 10, 0.2 );

    exec_command( [ 'multipathd', 'add', 'map', $wwid ], -1 ) unless multipath_check($wwid);
    return $path;
}

sub unmap_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname ) = @_;
    assert_vm_disk_storage($scfg);
    my $vol = sf_find_volume( $scfg, $storeid, $volname );
    return 0 unless $vol;

    my ( $path, $wwid ) = sf_get_device_path($vol);
    return 0 unless $path && -b $path;

    my ( $device_path, @slaves ) = block_device_slaves($path);
    exec_command( [ 'blockdev', '--flushbufs', $device_path ], -1 );

    if ( multipath_check($wwid) ) {
        exec_command( [ 'multipathd', 'remove', 'map', $wwid ], -1 );
    }

    block_device_action( 'remove', @slaves );
    return 1;
}

sub activate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;
    $class->map_volume( $storeid, $scfg, $volname, $snapname );
    return 1;
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;
    $class->unmap_volume( $storeid, $scfg, $volname, $snapname );
    return 1;
}

sub volume_resize {
    my ( $class, $scfg, $storeid, $volname, $size, $running, $snapname ) = @_;
    assert_vm_disk_storage($scfg);
    die "Resizing a SolidFire snapshot is not supported.\n" if defined $snapname;
    my $vol = sf_find_volume( $scfg, $storeid, $volname ) or die "Error :: Volume $volname not found.";
    solidfire_modify_volume( $scfg, $storeid, $vol->{volumeID}, { totalSize => $size } );

    my ( $path, $wwid ) = sf_get_device_path($vol);
    return unless $path && -b $path;

    my ( $device_path, @slaves ) = block_device_slaves($path);
    block_device_action( 'rescan', @slaves );
    exec_command( [ 'multipathd', 'resize', 'map', $wwid ], -1 ) if multipath_check($wwid);

    my $new_size;
    my $updated_size = sub {
        $new_size = get_device_size($device_path);
        return $new_size >= $size;
    };
    wait_for( $updated_size, "volume $volname size update", 10, 0.2 );
    return;
}

sub rename_volume {
    my ( $class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname ) = @_;
    assert_vm_disk_storage($scfg);
    die "Error :: not implemented in storage plugin $class.\n" if $class->can('api') && $class->api() < 10;
    $target_volname = $class->find_free_diskname( $storeid, $scfg, $target_vmid ) unless length $target_volname;

    my $vol = sf_find_volume( $scfg, $storeid, $source_volname ) or die "Error :: Volume $source_volname not found.";
    sf_api_request( $scfg, $storeid, 'ModifyVolume', { volumeID => $vol->{volumeID}, name => $target_volname } );
    return "$storeid:$target_volname";
}

# -- Snapshots -------------------------------------------------------------------

sub volume_snapshot {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
    assert_vm_disk_storage($scfg);
    my $vol = sf_find_volume( $scfg, $storeid, $volname ) or die "Error :: Volume $volname not found.";
    sf_api_request( $scfg, $storeid, 'CreateSnapshot', { volumeID => $vol->{volumeID}, name => $snap } );
    return 1;
}

sub volume_snapshot_rollback {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
    assert_vm_disk_storage($scfg);
    my $vol = sf_find_volume( $scfg, $storeid, $volname ) or die "Error :: Volume $volname not found.";
    my $snapid = sf_find_snapshot_id( $scfg, $storeid, $vol->{volumeID}, $snap );
    sf_api_request( $scfg, $storeid, 'RollbackToSnapshot', { volumeID => $vol->{volumeID}, snapshotID => $snapid } );
    return 1;
}

sub volume_snapshot_delete {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
    assert_vm_disk_storage($scfg);
    my $vol = sf_find_volume( $scfg, $storeid, $volname ) or die "Error :: Volume $volname not found.";
    my $snapid = sf_find_snapshot_id( $scfg, $storeid, $vol->{volumeID}, $snap );
    sf_api_request( $scfg, $storeid, 'DeleteSnapshot', { snapshotID => $snapid } );
    return 1;
}

sub volume_has_feature {
    my ( $class, $scfg, $feature, $storeid, $volname, $snapname, $running ) = @_;
    return undef if defined $scfg->{'sf-lun-size-gib'};
    my $features = {
        copy       => { current => 1, snap => 1 },
        clone      => { current => 1, snap => 1 },
        snapshot   => { current => 1 },
        sparseinit => { current => 1 },
        rename     => { current => 1 },
    };
    my ( $vtype, undef, undef, undef, undef, $isBase ) = $class->parse_volname($volname);
    my $key = $snapname ? 'snap' : $isBase ? 'base' : 'current';
    return 1 if $features->{$feature}->{$key};
    return undef;
}

1;
