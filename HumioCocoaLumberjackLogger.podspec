Pod::Spec.new do |s|
  s.name = 'HumioCocoaLumberjackLogger'
  s.version  = '0.0.1'
  s.license = 'MIT'
  s.summary  = 'Sends your Lumberjack logging directly to Humio'
  s.homepage = 'https://cloud.humio.com'
  s.authors   = { 'Jimmy Juncker' => '' }
  s.source = { :git => 'https://github.com/jjuncker/HumioCocoaLumberjackLogger', :tag => s.version }

  s.ios.deployment_target = '8.0'
  s.source_files = 'Classes/*.swift'
  s.dependency 'CocoaLumberjack', '~> 2.4.0'
  
end