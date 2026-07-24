// Panel tamamen kapalıyken (sekme/tarayıcı kapalı) de bildirim gösterebilmek
// için Firebase Cloud Messaging'in arka plan işleyicisi aynı service
// worker'a ekleniyor — ayrı bir firebase-messaging-sw.js dosyasına gerek
// yok, messaging.getToken() bu kayıtlı worker'ı doğrudan kullanabiliyor.
importScripts('https://www.gstatic.com/firebasejs/10.7.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.7.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyCy-CSxZGg4AJb_nNZlSLvQ2-56v7ETg2I',
  authDomain: 'uyari-f25c4.firebaseapp.com',
  databaseURL: 'https://uyari-f25c4-default-rtdb.europe-west1.firebasedatabase.app',
  projectId: 'uyari-f25c4',
  storageBucket: 'uyari-f25c4.firebasestorage.app',
  messagingSenderId: '93986217590',
  appId: '1:93986217590:web:d5c1b676b09599ed92c957',
});

const messaging = firebase.messaging();
messaging.onBackgroundMessage((payload) => {
  const title = payload.notification?.title || payload.data?.title || 'UZAKDUR Admin';
  const body = payload.notification?.body || payload.data?.body || '';
  self.registration.showNotification(title, { body });
});

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window' }).then((list) => {
    if (list.length > 0) return list[0].focus();
    return self.clients.openWindow('./');
  }));
});
