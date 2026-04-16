#!/bin/bash
source common.sh
set_keys
export VERSION=$(grep -m1 -o '[0-9]\+\(\.[0-9]\+\)\{3\}' vanadium/args.gn)
export CHROMIUM_SOURCE=https://chromium.googlesource.com/chromium/src.git # https://github.com/chromium/chromium.git
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y sudo lsb-release file nano git curl python3 python3-pillow

# https://github.com/uazo/cromite/blob/master/tools/images/chr-source/prepare-build.sh
git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$PWD/depot_tools:$PATH"
mkdir -p chromium/src/out/Default; cd chromium
gclient root; cd src
git init
git remote add origin $CHROMIUM_SOURCE
git fetch --depth 2 $CHROMIUM_SOURCE +refs/tags/$VERSION:chromium_$VERSION
git checkout $VERSION
export COMMIT=$(git show-ref -s $VERSION | head -n1)
cat > ../.gclient <<EOF
solutions = [
  {
    "name": "src",
    "url": "$CHROMIUM_SOURCE@$COMMIT",
    "deps_file": "DEPS",
    "managed": False,
    "custom_vars": {
      "checkout_android_prebuilts_build_tools": True,
      "checkout_telemetry_dependencies": False,
      "codesearch": "Debug",
    },
  },
]
target_os = ["android"]
EOF
git submodule foreach git config -f ./.git/config submodule.$name.ignore all
git config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'

# https://grapheneos.org/build#browser-and-webview
rm -rf $SCRIPT_DIR/vanadium/patches/*trichrome-{apk-build-targets,browser-apk-targets}.patch
replace "$SCRIPT_DIR/vanadium/patches" "VANADIUM" "HELIUM"
replace "$SCRIPT_DIR/vanadium/patches" "Vanadium" "Helium"
replace "$SCRIPT_DIR/vanadium/patches" "vanadium" "helium"
git am --whitespace=nowarn --keep-non-patch $SCRIPT_DIR/vanadium/patches/*.patch

gclient sync -D --no-history --nohooks
gclient runhooks
rm -rf third_party/angle/third_party/VK-GL-CTS/
./build/install-build-deps.sh --no-prompt

# https://github.com/imputnet/helium-linux/blob/main/scripts/shared.sh
# python3 "${SCRIPT_DIR}/helium/utils/name_substitution.py" --sub -t .
# python3 "${SCRIPT_DIR}/helium/utils/helium_version.py" --tree "${SCRIPT_DIR}/helium" --chromium-tree .
# python3 "${SCRIPT_DIR}/helium/utils/generate_resources.py" "${SCRIPT_DIR}/helium/resources/generate_resources.txt" "${SCRIPT_DIR}/helium/resources"
# python3 "${SCRIPT_DIR}/helium/utils/replace_resources.py" "${SCRIPT_DIR}/helium/resources/helium_resources.txt" "${SCRIPT_DIR}/helium/resources" .

# === Migaku popup-to-tab conversion + lifecycle exemption ===

# 1. Force popups to open as tabs (render_frame_impl.cc)
#    Replace the popup case to always return NEW_FOREGROUND_TAB
sed -i '/case blink::kWebNavigationPolicyNewPopup:/{
  n
  s/.*return WindowOpenDisposition::NEW_POPUP;/      return WindowOpenDisposition::NEW_FOREGROUND_TAB;/
}' content/renderer/render_frame_impl.cc

# 2. Force popups to tabs in mojo serialization (browser side)
#    Serializer: NEW_POPUP -> NEW_FOREGROUND_TAB
sed -i '/case WindowOpenDisposition::NEW_POPUP:/{
  n
  s/.*return ui::mojom::WindowOpenDisposition::NEW_POPUP;/        return ui::mojom::WindowOpenDisposition::NEW_FOREGROUND_TAB;/
}' ui/base/mojom/window_open_disposition_mojom_traits.h

#    Deserializer: NEW_POPUP -> NEW_FOREGROUND_TAB
sed -i 's/\*out = WindowOpenDisposition::NEW_POPUP;/*out = WindowOpenDisposition::NEW_FOREGROUND_TAB;/' \
  ui/base/mojom/window_open_disposition_mojom_traits.h

# 3. Mark converted popup tabs as non-auto-discardable (browser.cc)
#    Add include for PageLiveStateDecorator
sed -i '/#include "chrome\/browser\/ui\/browser.h"/a #include "components/performance_manager/public/decorators/page_live_state_decorator.h"' \
  chrome/browser/ui/browser.cc

#    In AddNewContents, detect converted popups and exempt from lifecycle
sed -i '/bool\* was_blocked) {/{
  a\  // Migaku: exempt converted popup tabs from freezing/discarding\
  if (window_features.is_popup \&\&\
      disposition != WindowOpenDisposition::NEW_POPUP) {\
    performance_manager::PageLiveStateDecorator::SetIsAutoDiscardable(\
        new_contents.get(), false);\
  }
}' chrome/browser/ui/browser.cc

# 4. Make FreezingPolicy respect IsAutoDiscardable (freezing_policy.h)
#    Add OnIsAutoDiscardableChanged override declaration
sed -i '/void OnIsBeingMirroredChanged(const PageNode\* page_node) override;/a\  void OnIsAutoDiscardableChanged(const PageNode* page_node) override;' \
  components/performance_manager/freezing/freezing_policy.h

# 5. Implement OnIsAutoDiscardableChanged in FreezingPolicy (freezing_policy.cc)
#    Add implementation after OnIsBeingMirroredChanged
sed -i '/^void FreezingPolicy::OnIsBeingMirroredChanged/,/^}$/{
  /^}$/a\
\
void FreezingPolicy::OnIsAutoDiscardableChanged(const PageNode* page_node) {\
  auto* live_state_data =\
      PageLiveStateDecorator::Data::FromPageNode(page_node);\
  bool is_not_auto_discardable =\
      live_state_data \&\& !live_state_data->IsAutoDiscardable();\
  OnCannotFreezeReasonChange(page_node, /*add=*/is_not_auto_discardable,\
                             CannotFreezeReason::kOptedOut);\
}
}' components/performance_manager/freezing/freezing_policy.cc

# 6. Fix CHECK crash in TabsQueryFunction::MatchesWindow (tabs_api.cc)
#    On Android, some windows (CustomTabActivity) lack a BrowserExtensionWindowController.
#    Convert fatal CHECK to defensive skip.
sed -i 's|  CHECK(window_controller);|  if (!window_controller) return false;|' \
  chrome/browser/extensions/api/tabs/tabs_api.cc

# 7. Coerce extension popup windows to normal type (tabs_api.cc)
#    Prevents chrome.windows.create({type:"popup"}) from creating CustomTabActivity.
sed -i 's|        window_type = BrowserWindowInterface::TYPE_POPUP;|        window_type = BrowserWindowInterface::TYPE_NORMAL;|' \
  chrome/browser/extensions/api/tabs/tabs_api.cc

# 8. Redirect chrome.windows.create to open as tab in existing window (tabs_api.cc)
#    Instead of creating a new Android Activity, reuse the current browser window.
python3 << 'PYEOF'
path = "chrome/browser/extensions/api/tabs/tabs_api.cc"
with open(path) as f: src = f.read()

old = """#else

  CHECK(create_params.type == BrowserWindowInterface::TYPE_NORMAL ||
        create_params.type == BrowserWindowInterface::TYPE_POPUP)
      << "Unexpected window type: " << static_cast<int>(create_params.type);

  CreateBrowserWindow(
      std::move(create_params),
      base::BindOnce(
          &WindowsCreateFunction::OnBrowserWindowCreatedAsynchronously, this));
  return RespondLater();
#endif  // BUILDFLAG(IS_ANDROID)"""

new = """#else

  // Migaku: On Android, chrome.windows.create opens URLs as tabs in the
  // existing browser window instead of creating a new Activity/Task.
  BrowserWindowInterface* existing = nullptr;
  for (auto* b : GetAllBrowserWindowInterfaces()) {
    if (b->GetProfile() == window_profile) {
      existing = b;
      break;
    }
  }
  if (existing) {
    for (const GURL& url : urls_) {
      NavigateParams nav_params(existing, url, ui::PAGE_TRANSITION_LINK);
      nav_params.disposition = WindowOpenDisposition::NEW_FOREGROUND_TAB;
      nav_params.pwa_navigation_capturing_force_off = true;
      Navigate(&nav_params);
    }
    return RespondNow(WithArguments(
        ExtensionTabUtil::CreateWindowValueForExtension(
            *existing, extension(), WindowController::kPopulateTabs,
            source_context_type())));
  }

  CreateBrowserWindow(
      std::move(create_params),
      base::BindOnce(
          &WindowsCreateFunction::OnBrowserWindowCreatedAsynchronously, this));
  return RespondLater();
#endif  // BUILDFLAG(IS_ANDROID)"""

if old in src:
    src = src.replace(old, new)
    with open(path, "w") as f: f.write(src)
    print("PATCHED windows.create redirect")
else:
    print("WARNING: windows.create marker not found, may already be patched")
PYEOF

# === End Migaku patches ===

sed -i 's/BASE_FEATURE(kExtensionManifestV2Unsupported, base::FEATURE_ENABLED_BY_DEFAULT);/BASE_FEATURE(kExtensionManifestV2Unsupported, base::FEATURE_DISABLED_BY_DEFAULT);/' extensions/common/extension_features.cc
sed -i 's/BASE_FEATURE(kExtensionManifestV2Disabled, base::FEATURE_ENABLED_BY_DEFAULT);/BASE_FEATURE(kExtensionManifestV2Disabled, base::FEATURE_DISABLED_BY_DEFAULT);/' extensions/common/extension_features.cc
sed -i '/feature_overrides.EnableFeature(::features::kSkipVulkanBlocklist);/d' chrome/browser/chrome_browser_field_trials.cc
sed -i '/feature_overrides.EnableFeature(::features::kDefaultANGLEVulkan);/d' chrome/browser/chrome_browser_field_trials.cc
sed -i '/feature_overrides.EnableFeature(::features::kVulkanFromANGLE);/d' chrome/browser/chrome_browser_field_trials.cc
sed -i '/feature_overrides.EnableFeature(::features::kDefaultPassthroughCommandDecoder);/d' chrome/browser/chrome_browser_field_trials.cc
: << TOOLBAR_PHONE
sed -i '/<ViewStub/{N;N;N;N;N;N; /optional_button_stub/a\
\
        <ViewStub\
            android:id="@+id/extension_toolbar_container_stub"\
            android:inflatedId="@+id/extension_toolbar_container"\
            android:layout_width="wrap_content"\
            android:layout_height="match_parent" />
}' chrome/browser/ui/android/toolbar/java/res/layout/toolbar_phone.xml
sed -i 's/extension_toolbar_baseline_width">600dp/extension_toolbar_baseline_width">0dp/' chrome/browser/ui/android/extensions/java/res/values/dimens.xml
TOOLBAR_PHONE

cat > out/Default/args.gn <<EOF
chrome_public_manifest_package = "io.github.jqssun.helium"
is_desktop_android = true
target_os = "android"
target_cpu = "arm64"
is_component_build = false
is_debug = false
is_official_build = true
symbol_level = 1
disable_fieldtrial_testing_config = true
ffmpeg_branding = "Chrome"
proprietary_codecs = true
enable_vr = false
enable_arcore = false
enable_openxr = false
enable_cardboard = false
enable_remoting = false
enable_reporting = false
google_api_key = "x"
google_default_client_id = "x"
google_default_client_secret = "x"

use_siso = true
use_login_database_as_backend = false
build_contextual_search = false
build_with_tflite_lib = true
dcheck_always_on = false
enable_iterator_debugging = false
exclude_unwind_tables = false
icu_use_data_file = true
rtc_build_examples = false
use_errorprone_java_compiler = false
use_rtti = false
enable_av1_decoder = true
enable_dav1d_decoder = true
include_both_v8_snapshots = false
include_both_v8_snapshots_android_secondary_abi = false
generate_linker_map = true
EOF
gn gen out/Default # gn args out/Default; echo 'treat_warnings_as_errors = false' >> out/Default/args.gn
autoninja -C out/Default chrome_public_apk
mkdir -p out/tmp out/release
mv $(find out/Default/apks -name 'Chrome*.apk') out/tmp/$VERSION-arm64-v8a.apk

sudo dpkg --add-architecture i386; sudo apt-get update; sudo apt-get install -y libgcc-s1:i386  
sed -i 's/target_cpu = "arm64"/target_cpu = "arm"/' out/Default/args.gn
autoninja -C out/Default chrome_public_apk
mv $(find out/Default/apks -name 'Chrome*.apk') out/tmp/$VERSION-armeabi-v7a.apk

export PATH=$PWD/third_party/jdk/current/bin/:$PATH
export ANDROID_HOME=$PWD/third_party/android_sdk/public
sign_apk out/tmp/$VERSION-arm64-v8a.apk out/release/$VERSION-arm64-v8a.apk
sign_apk out/tmp/$VERSION-armeabi-v7a.apk out/release/$VERSION-armeabi-v7a.apk
rm -rf $SCRIPT_DIR/keys
