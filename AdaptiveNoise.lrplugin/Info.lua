local menuItems = {
    { title = 'Adaptive Noise Reduction...', file = 'Main.lua' },
}
return {
    LrSdkVersion = 6.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = 'com.ryansmith.lightroom.adaptive-noise',
    LrPluginName = 'Adaptive Noise',
    LrPluginInfoUrl = 'https://github.com/rsmith4321/lightroom-adaptive-noise',
    VERSION = { major = 1, minor = 1, revision = 1, build = 1 },
    LrLibraryMenuItems = menuItems,
    LrExportMenuItems = menuItems,
}
