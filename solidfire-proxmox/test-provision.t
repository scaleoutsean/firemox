use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;
use PVE::Storage;

require $ENV{FIREMOX_PLUGIN_PATH}
    unless defined &PVE::Storage::Custom::SolidFirePlugin::sf_credentials_path;

my $class = 'PVE::Storage::Custom::SolidFirePlugin';
my $dir = tempdir(CLEANUP => 1);
my $config = {
    accountid => 2,
    content => { none => 1 },
    'sf-lun-size-gib' => 2,
};
my ($existing, @created, @resized);

no warnings 'redefine';
local *PVE::Storage::Custom::SolidFirePlugin::sf_credentials_path =
    sub { return "$dir/$_[0].pw" };
local *PVE::Storage::Custom::SolidFirePlugin::sf_find_volume =
    sub { return $existing };
local *PVE::Storage::Custom::SolidFirePlugin::solidfire_create_volume =
    sub { @created = @_; return { volumeID => 42 } };
local *PVE::Storage::Custom::SolidFirePlugin::solidfire_modify_volume =
    sub { @resized = @_; return {} };
local *PVE::Storage::Custom::SolidFirePlugin::sf_get_device_path =
    sub { return ('', '') };

eval { $class->on_add_hook('no-password', $config) };
like($@, qr/password is required/, 'rejects a missing password');

eval {
    $class->on_add_hook('wrong-content', { %$config, content => { images => 1 } }, password => 'test');
};
like($@, qr/requires content 'none'/, 'does not present a provisioned LUN as VM storage');
ok(!-e "$dir/wrong-content.pw", 'invalid content does not leave credentials');

$existing = { volumeID => 7 };
eval { $class->on_add_hook('duplicate', $config, password => 'test') };
like($@, qr/already exists/, 'does not create a duplicate LUN');
ok(!-e "$dir/duplicate.pw", 'failed provisioning removes credentials');
is(scalar @created, 0, 'duplicate does not call CreateVolume');

$existing = undef;
$class->on_add_hook('test-lun', $config, password => 'test');
is_deeply(\@created, [$config, 'test-lun', 'test-lun', 2 * 1024 * 1024 * 1024],
    'uses the storage ID and converts GiB to bytes');
is((stat("$dir/test-lun.pw"))[2] & 0777, 0600, 'credential file is restricted');

$class->on_update_hook_full('test-lun', $config, {}, [], { password => 'new-test-password' });
is(PVE::Tools::file_get_contents("$dir/test-lun.pw"), 'new-test-password',
    'API 13+ update hook forwards a password change');
eval { $class->on_update_hook_full('test-lun', $config, {}, [], { password => undef }) };
like($@, qr/password cannot be empty/, 'API 13+ update hook rejects password removal');
is(PVE::Tools::file_get_contents("$dir/test-lun.pw"), 'new-test-password',
    'rejected password removal preserves credentials');

$existing = { volumeID => 42 };
eval { $class->alloc_image('test-lun', $config, 100, 'raw', undef, 1024) };
like($@, qr/not a VM disk datastore/, 'provisioning entry cannot allocate VM disks');
eval { $class->free_image('test-lun', $config, 'vm-100-disk-0') };
like($@, qr/not a VM disk datastore/, 'provisioning entry cannot delete VM disks');
is_deeply($class->list_images('test-lun', $config), [], 'provisioning entry has no VM disks');

$existing = { volumeID => 42 };
my $disk_config = { accountid => 2 };
$class->volume_resize($disk_config, 'test-lun', 'vm-100-disk-0', 2147483648, 0);
is($resized[3]->{totalSize}, 2147483648, 'VM disk resize passes bytes unchanged');
@resized = ();
eval {
    $class->volume_resize($disk_config, 'test-lun', 'vm-100-disk-0', 2147483648, 0, 'snapshot');
};
like($@, qr/Resizing a SolidFire snapshot is not supported/, 'snapshot resize is rejected');
is(scalar @resized, 0, 'snapshot resize does not modify the current volume');

$class->on_delete_hook('test-lun', $config);
ok(!-e "$dir/test-lun.pw", 'storage removal deletes credentials');

done_testing();
