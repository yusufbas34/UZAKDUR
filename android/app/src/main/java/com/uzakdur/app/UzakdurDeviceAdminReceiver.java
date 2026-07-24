package com.uzakdur.app;

import android.app.admin.DeviceAdminReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import com.google.firebase.FirebaseApp;
import com.google.firebase.database.FirebaseDatabase;
import com.google.firebase.database.ServerValue;
import java.util.HashMap;
import java.util.Map;

// Android'de gerçek, şifreyle korunan bir "silme engeli" yok — Cihaz
// Yöneticisi (Device Admin) izni, uygulamayı silmeden önce kullanıcının bu
// izni elle kapatmasını ZORUNLU kılan tek genel mekanizma. Asıl değeri
// engellemek değil, bu adımın anında yakalanıp bildirilmesi: onDisabled()
// tam olarak "biri uygulamayı silmeye hazırlanıyor" anında, Flutter motoru
// o sırada hiç çalışmıyor olsa bile tetiklenir — bu yüzden Firebase'e
// doğrudan native koddan yazıyoruz.
public class UzakdurDeviceAdminReceiver extends DeviceAdminReceiver {

    @Override
    public void onDisabled(Context context, Intent intent) {
        super.onDisabled(context, intent);
        final PendingResult pendingResult = goAsync();
        try {
            SharedPreferences prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE);
            String deviceId = prefs.getString("flutter.device_id", null);
            if (deviceId == null || deviceId.isEmpty()) {
                pendingResult.finish();
                return;
            }
            if (FirebaseApp.getApps(context).isEmpty()) {
                FirebaseApp.initializeApp(context);
            }
            Map<String, Object> event = new HashMap<>();
            event.put("msg", "Cihaz yöneticisi izni kapatıldı — uygulama silinmek üzere olabilir");
            event.put("ts", ServerValue.TIMESTAMP);
            FirebaseDatabase.getInstance().getReference("devices/" + deviceId + "/uninstallAttempt")
                    .setValue(event)
                    .addOnCompleteListener(task -> pendingResult.finish());
        } catch (Exception e) {
            // Bu son çare bir bildirim — burada yapabileceğimiz başka bir şey
            // yok, uygulama zaten silinmek üzere olabilir.
            pendingResult.finish();
        }
    }
}
