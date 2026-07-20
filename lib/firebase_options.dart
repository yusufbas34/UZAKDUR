import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError('Bu platform için FirebaseOptions tanımlı değil.');
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyC2ekoI-oHqM2jPWjPJp6uUCxJXCydqIuE',
    appId: '1:93986217590:android:721a15dc810e3f5a92c957',
    messagingSenderId: '93986217590',
    projectId: 'uyari-f25c4',
    databaseURL: 'https://uyari-f25c4-default-rtdb.europe-west1.firebasedatabase.app',
    storageBucket: 'uyari-f25c4.firebasestorage.app',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyC2ekoI-oHqM2jPWjPJp6uUCxJXCydqIuE',
    appId: '1:93986217590:android:721a15dc810e3f5a92c957',
    messagingSenderId: '93986217590',
    projectId: 'uyari-f25c4',
    databaseURL: 'https://uyari-f25c4-default-rtdb.europe-west1.firebasedatabase.app',
    storageBucket: 'uyari-f25c4.firebasestorage.app',
    authDomain: 'uyari-f25c4.firebaseapp.com',
  );
}
