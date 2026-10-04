/* Sistema RAVE · funcionamiento sin conexión del menú y del sistema.
   Primero la red (siempre la versión más nueva); si no hay internet, lo
   último guardado. Sólo guarda archivos de este sitio: nunca datos de la nube. */
var CACHE = 'rave-v1.1';
self.addEventListener('install', function(e){
  e.waitUntil(caches.open(CACHE).then(function(c){ return c.addAll(['./', './manifest.webmanifest', './icono-192.png']); }).then(function(){ return self.skipWaiting(); }));
});
self.addEventListener('activate', function(e){
  e.waitUntil(caches.keys().then(function(ks){
    return Promise.all(ks.filter(function(k){ return k !== CACHE; }).map(function(k){ return caches.delete(k); }));
  }).then(function(){ return self.clients.claim(); }));
});
self.addEventListener('fetch', function(e){
  var r = e.request;
  if(r.method !== 'GET' || new URL(r.url).origin !== self.location.origin) return;
  e.respondWith(fetch(r).then(function(res){
    if(res && res.ok && res.type === 'basic'){
      var copia = res.clone();
      caches.open(CACHE).then(function(c){ c.put(r, copia); });
    }
    return res;
  }).catch(function(){
    return caches.match(r).then(function(m){ return m || caches.match('./'); });
  }));
});
