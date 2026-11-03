#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_cache_maestro.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_cache_maestro'
  s.version          = '0.2.0'
  s.summary          = 'Offline-first file cache for Flutter.'
  s.description      = <<-DESC
Keeps the flutter_cache_maestro cache directory out of iCloud backups.
                       DESC
  s.homepage         = 'https://github.com/kibukamusoke/flutter_cache_maestro'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'kibukamusoke'
  s.source           = { :path => '.' }
  s.source_files = 'flutter_cache_maestro/Sources/flutter_cache_maestro/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
