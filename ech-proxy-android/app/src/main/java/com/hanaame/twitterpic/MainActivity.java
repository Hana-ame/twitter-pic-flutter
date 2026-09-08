package com.hanaame.twitterpic;

import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.widget.Toast;
import androidx.appcompat.app.AppCompatActivity;
import java.net.InetAddress;

public class MainActivity extends AppCompatActivity {

    private static final String TAG = "TwitterPic";

    // JNI 调用 Go 代理
    private native int nativeStartProxy(String bootstrapIP);
    private native void nativeStopProxy();
    private native int nativeGetProxyPort();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // 加载 ECH 代理库
        try {
            System.loadLibrary("echproxy");
            Log.d(TAG, "libechproxy.so loaded");
        } catch (UnsatisfiedLinkError e) {
            Log.e(TAG, "Failed to load libechproxy.so", e);
            Toast.makeText(this, "加载失败: " + e.getMessage(), Toast.LENGTH_LONG).show();
            finish();
            return;
        }

        // 启动代理
        startProxy();
    }

    private void startProxy() {
        // 检查端口是否已在运行
        int port = nativeGetProxyPort();
        if (port > 0) {
            openBrowser(port);
            return;
        }

        // 新启动代理
        String bootstrapIP = resolveBootstrapIP();
        int newPort = nativeStartProxy(bootstrapIP);

        if (newPort > 0) {
            Log.d(TAG, "Proxy started on port " + newPort);
            openBrowser(newPort);
        } else {
            Log.e(TAG, "Failed to start proxy");
            Toast.makeText(this, "启动代理失败", Toast.LENGTH_LONG).show();
        }
    }

    private String resolveBootstrapIP() {
        try {
            InetAddress[] addresses = InetAddress.getAllByName("moonchan.xyz");
            for (InetAddress addr : addresses) {
                String host = addr.getHostAddress();
                if (host != null && !host.contains(":")) {
                    Log.d(TAG, "Resolved moonchan.xyz to " + host);
                    return host;
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "DNS resolution failed", e);
        }
        return null;
    }

    private void openBrowser(int port) {
        String url = "http://127.0.0.1:" + port + "/";
        Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
        startActivity(intent);
    }
}
