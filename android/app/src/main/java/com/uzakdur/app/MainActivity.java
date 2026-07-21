package com.uzakdur.app;

import android.content.ComponentName;
import android.content.pm.PackageManager;
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "uzakdur/disguise";

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
