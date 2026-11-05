// WedryTrack service worker: keeps the app itself on the phone so it opens with no signal.
// Data is saved separately on the device and synced by the app.
const CACHE="wedrytrack-v2";
const SHELL=["./","index.html","config.js","manifest.webmanifest","icon.svg","icon-192.png","icon-512.png","wedry-logo-light.png"];
self.addEventListener("install",e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting()))});
self.addEventListener("activate",e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener("fetch",e=>{
  const url=new URL(e.request.url);
  if(e.request.method!=="GET"||url.origin!==location.origin) return;
  // Try the network for a fresh copy, but use the saved copy if the signal is too weak to answer in 4 seconds.
  const cached=()=>caches.match(e.request,{ignoreSearch:true}).then(r=>r||(e.request.mode==="navigate"?caches.match("index.html"):undefined));
  e.respondWith(new Promise(resolve=>{
    let done=false; const finish=r=>{ if(!done&&r){done=true;resolve(r)} };
    const t=setTimeout(()=>cached().then(finish),4000);
    fetch(e.request).then(r=>{ clearTimeout(t); if(r.ok){const c=r.clone();caches.open(CACHE).then(x=>x.put(e.request,c))} finish(r) })
      .catch(()=>{ clearTimeout(t); cached().then(r=>{ finish(r||Response.error()) }) });
  }));
});
