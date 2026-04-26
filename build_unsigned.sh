rm -rf build/DerivedData export && \
mkdir -p .build/source-packages build export/Payload && \
xcodebuild \
  -project "Immersive Reader.xcodeproj" \
  -scheme "Immersive Reader" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath .build/source-packages \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build && \
  cp -R "build/DerivedData/Build/Products/Release-iphoneos/ImmersiveReader.app" "export/Payload/" && \
  cd export && \
  zip -r "ImmersiveReader-unsigned.ipa" Payload
