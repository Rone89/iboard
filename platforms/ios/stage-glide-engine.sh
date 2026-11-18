#!/bin/sh
# 把 GlideKeyboard（MIT）的滑行引擎静态库与中文预编译词典暂存进 iBoard 的
# 构建树。三个词典文件是 Scripts/compile-chinese-data.sh 从同批 TSV 源数据
# 生成的匹配集（bind 于 wm-engine 的私有格式），引擎二进制与词典之间只锁
# 格式版本，不锁构建版本；换任一侧都要复核哈希。来源：
#   GlideKeyboard @ 0fcf00b（~/Desktop/GlideKeyboard，MIT，见其 NOTICE.md）
# 词典数据许可（CC BY-SA 4.0 等）随 App 资源分发，见 App/Resources 下的
# GlideEngine-LICENSE.txt 与 GlideEngine-NOTICE.txt。
set -eu
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source_root=${GLIDE_KEYBOARD_ROOT:-"$repo_root/../GlideKeyboard"}

device_dest="$repo_root/target/ios/device"
simulator_dest="$repo_root/target/ios/simulator"
dictionary_dest="$repo_root/target/ios/glide-engine"

xcframework="$source_root/build/GlideEngine.xcframework"
compiled="$source_root/build/compiled"

check() {
  echo "$2  $1" | shasum -a 256 -c - >&2
}

# 静态库：真机与模拟器切片各自进已有的 LIBRARY_SEARCH_PATHS 目录。
check "$xcframework/ios-arm64/libglide_ios_bridge.a" \
  5848ed6aa946e5766e8b0a1b443162886b561827c10be8cb1391b3524f2a3ed2
check "$xcframework/ios-arm64_x86_64-simulator/libglide_ios_bridge.a" \
  ad529df61b0fa09e5013c79fdac40d34ee49218ac24f7d08bea501459246352d
# 词典匹配集（与 GlideKeyboard Scripts/compile-chinese-data.sh 同一把锁）。
check "$compiled/glide.wmdict" \
  9b1a39c1cba35f0b19aeedfa89667fd9eed21ce2515a1d29d7b57b695e87cf6a
check "$compiled/ngrams.wmcn" \
  2602d4e69a96145aafb16f0d1538688b808a84d555e87e7433cc06a74bf512b1
check "$compiled/pinyin.wmcd" \
  20632f0eadd02a521c273f016f62eaf31ba1c1e3bf69c213d5ae7676d49ff500

cp "$xcframework/ios-arm64/libglide_ios_bridge.a" "$device_dest/libglide_ios_bridge.a"
cp "$xcframework/ios-arm64_x86_64-simulator/libglide_ios_bridge.a" "$simulator_dest/libglide_ios_bridge.a"

rm -rf "$dictionary_dest"
mkdir -p "$dictionary_dest"
cp "$compiled/glide.wmdict" "$compiled/ngrams.wmcn" "$compiled/pinyin.wmcd" "$dictionary_dest/"
cp "$source_root/LICENSE" "$dictionary_dest/LICENSE-GlideEngine.txt"
cp "$source_root/NOTICE.md" "$dictionary_dest/NOTICE-GlideEngine.md"

echo "GlideEngine staged: $device_dest, $simulator_dest, $dictionary_dest"
