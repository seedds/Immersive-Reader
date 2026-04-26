rm -rf build export && \
xcodebuild \
  -project "Immersive Reader.xcodeproj" \
  -scheme "Immersive Reader" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build && \
mkdir -p export/Payload && \
cp -R "build/Build/Products/Release-iphoneos/ImmersiveReader.app" "export/Payload/" && \
cd export && \
zip -r "ImmersiveReader-unsigned.ipa" Payload
