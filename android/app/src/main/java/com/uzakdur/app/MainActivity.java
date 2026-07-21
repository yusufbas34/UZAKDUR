package com.uzakdur.app;

import android.content.ComponentName;
import android.content.pm.PackageManager;
import android.view.KeyEvent;
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.util.ArrayDeque;
import java.util.Deque;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "uzakdur/disguise";
    private static final String PANIC_CHANNEL = "uzakdur/panic_keys";
    private static final int TRIGGER_PRESSES = 3;
    private static final long TRIGGER_WINDOW_MS = 2000;

    private MethodChannel panicChannel;
    private final Deque<Long> volumeUpPresses = new ArrayDeque<>();

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    switch (call.method) {
                        case "applyDisguise":
                            setDisguised(true);
                            result.success(null);
                            break;
                        case "removeDisguise":
                            setDisguised(false);
                            result.success(null);
                            break;
                        default:
                            result.notImplemented();
                    }
                });
        panicChannel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), PANIC_CHANNEL);
    }

    // Ses tuşuna arka arkaya 3 kez basmak, uzun basıştan daha hızlı ve daha
    // gizli bir panik tetikleyicisi sağlar. Bunun bilinen sınırı: Android'in
    // tuş olayları sadece bu Activity ön plandayken (ekran açık, uygulama
    // gösterilirken) ulaşır — kilit ekranından ya da başka bir uygulama
    // açıkken çalışmaz. Erişilebilirlik servisi gibi ağır bir izin
    // gerektirmeden elde edilebilecek en pratik çözüm bu.
    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (event.getKeyCode() == KeyEvent.KEYCODE_VOLUME_UP && event.getAction() == KeyEvent.ACTION_DOWN) {
            long now = System.currentTimeMillis();
            volumeUpPresses.addLast(now);
            while (!volumeUpPresses.isEmpty() && now - volumeUpPresses.peekFirst() > TRIGGER_WINDOW_MS) {
                volumeUpPresses.removeFirst();
            }
            if (volumeUpPresses.size() >= TRIGGER_PRESSES) {
                volumeUpPresses.clear();
                if (panicChannel != null) panicChannel.invokeMethod("triplePress", null);
            }
        }
        return super.dispatchKeyEvent(event);
    }

    private void setDisguised(boolean disguised) {
        PackageManager pm = getPackageManager();
        ComponentName realAlias = new ComponentName(this, "com.uzakdur.app.RealAlias");
        ComponentName disguiseAlias = new ComponentName(this, "com.uzakdur.app.DisguiseAlias");
        pm.setComponentEnabledSetting(disguiseAlias,
                disguised ? PackageManager.COMPONENT_ENABLED_STATE_ENABLED : PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP);
        pm.setComponentEnabledSetting(realAlias,
                disguised ? PackageManager.COMPONENT_ENABLED_STATE_DISABLED : PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP);
    }
}
