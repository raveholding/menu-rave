#!/usr/bin/env python3
"""Páginas públicas por producto: m/{comercio}/p/{producto}/index.html

Cada página tiene las etiquetas Open Graph (foto, nombre, precio) para que el
enlace se vea con vista previa en WhatsApp y redes, datos estructurados
schema.org/Product para Google, y lleva al menú abierto en ese producto.

Fuentes del catálogo:
  · el catálogo que viene dentro de index.html (comercio por defecto), y
  · los menús publicados en la nube (tabla pública `menus`), si hay red.
Uso:  python3 paginas_producto.py <carpeta-del-sitio> [--sin-nube]
La URL de la nube y la clave PUBLICABLE salen de index.html (son públicas).
"""
import base64, html, json, os, re, shutil, sys, urllib.request
from datetime import date

SITIO = sys.argv[1] if len(sys.argv) > 1 else '.'
SIN_NUBE = '--sin-nube' in sys.argv
BASE = 'https://raveholding.github.io/menu-rave/'
DEF_SLUG = 'rave'
RH = 'Sistema RAVE · desarrollado por Rave Holding'

idx = open(os.path.join(SITIO, 'index.html'), encoding='utf-8').read()
m = re.search(r'/\*__CATALOGO_DATOS__\*/(.*?)/\*__FIN_DATOS__\*/', idx, re.S)
cat_local = json.loads(m.group(1)) if m else {'secciones': [], 'productos': []}
nombre_local = (re.search(r'og:site_name" content="([^"]+)"', idx) or [None, 'RAVE'])[1]

menus = {DEF_SLUG: {'nombre': nombre_local, 'd': cat_local}}
if not SIN_NUBE:
    u = re.search(r"var NUBE = \{ url:'([^']+)', key:'([^']+)'", idx)
    if u and u.group(1).startswith('https://'):
        try:
            req = urllib.request.Request(u.group(1) + '/rest/v1/menus?select=slug,datos', headers={'apikey': u.group(2)})
            for fila in json.load(urllib.request.urlopen(req, timeout=30)):
                d = fila.get('datos') or {}
                if fila.get('slug') and d.get('productos'):
                    previo = menus.get(fila['slug'], {})
                    menus[fila['slug']] = {'nombre': d.get('comercio') or previo.get('nombre') or fila['slug'], 'd': d}
        except Exception as e:  # sin red: quedan las del archivo
            print('aviso: no se pudo leer la nube:', e)

def precio(n):
    try:
        return '$ ' + f'{round(float(n)):,}'.replace(',', '.')
    except Exception:
        return ''

def seguro(s):
    return re.sub(r'[^a-zA-Z0-9._-]', '-', str(s))[:80] or 'producto'

raiz = os.path.join(SITIO, 'm')
if os.path.isdir(raiz):
    shutil.rmtree(raiz)
urls = []
for slug, info in menus.items():
    slug_s = seguro(slug).lower()
    menu_url = BASE + ('' if slug == DEF_SLUG else '?m=' + slug_s)
    for p in info['d'].get('productos', []):
        pid = seguro(p.get('id'))
        carpeta = os.path.join(raiz, slug_s, 'p', pid)
        os.makedirs(carpeta, exist_ok=True)
        url = f'{BASE}m/{slug_s}/p/{pid}/'
        img = p.get('img') or ''
        img_url = BASE + 'img/og.jpg'
        if img.startswith('data:image/'):
            mt = re.match(r'data:image/(jpeg|jpg|png|webp);base64,([A-Za-z0-9+/=\s]*)$', img, re.S)
            datos = b''
            if mt:
                try:
                    datos = base64.b64decode(mt.group(2))
                except Exception:
                    datos = b''
            # sólo fotos de verdad (se revisan los primeros bytes); cualquier otra cosa → imagen genérica
            tipo = ('jpg' if datos[:3] == b'\xff\xd8\xff' else 'png' if datos[:8] == b'\x89PNG\r\n\x1a\n'
                    else 'webp' if datos[:4] == b'RIFF' and datos[8:12] == b'WEBP' else None)
            if tipo:
                ext = tipo
                if ext == 'webp':  # WhatsApp prefiere JPEG
                    try:
                        from PIL import Image
                        import io
                        b = io.BytesIO()
                        Image.open(io.BytesIO(datos)).convert('RGB').save(b, 'JPEG', quality=85)
                        datos, ext = b.getvalue(), 'jpg'
                    except Exception:
                        pass
                open(os.path.join(carpeta, 'foto.' + ext), 'wb').write(datos)
                img_url = url + 'foto.' + ext
        elif img and re.match(r'^(https://[^\s"\'<>]+|[\w./-]+\.(jpe?g|png|webp|avif))$', img, re.I):
            img_url = img if img.startswith('https://') else BASE + img.lstrip('./')
        nom = p.get('nom', '') + (f" ({p['sub']})" if p.get('sub') else '')
        pr = precio(p.get('precio'))
        local = info['nombre']
        destino = menu_url + ('&' if '?' in menu_url else '?') + 'p=' + pid
        desc = (p.get('desc') or '') or f'{nom} a {pr} en {local}. Pedilo por WhatsApp desde el menú digital.'
        ld = {
            '@context': 'https://schema.org', '@type': 'Product', 'name': nom, 'image': img_url,
            'description': desc, 'url': url,
            'offers': {'@type': 'Offer', 'price': str(p.get('precio', '')), 'priceCurrency': 'ARS', 'url': url,
                       'availability': 'https://schema.org/' + ('OutOfStock' if p.get('agotado') else 'InStock'),
                       'seller': {'@type': 'Organization', 'name': local}}
        }
        e = html.escape
        pagina = f'''<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{e(nom)} · {e(pr)} · {e(local)}</title>
<meta name="description" content="{e(desc)}">
<link rel="canonical" href="{e(url)}">
<meta property="og:type" content="product">
<meta property="og:site_name" content="{e(local)}">
<meta property="og:title" content="{e(nom)} · {e(pr)}">
<meta property="og:description" content="{e(desc)}">
<meta property="og:image" content="{e(img_url)}">
<meta property="og:url" content="{e(url)}">
<meta property="product:price:amount" content="{e(str(p.get('precio', '')))}">
<meta property="product:price:currency" content="ARS">
<meta name="twitter:card" content="summary_large_image">
<meta name="generator" content="{RH}">
<meta http-equiv="refresh" content="0;url={e(destino)}">
<script type="application/ld+json">{json.dumps(ld, ensure_ascii=False).replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')}</script>
<style>body{{font-family:system-ui,sans-serif;background:#171513;color:#f3eee4;display:flex;min-height:100vh;align-items:center;justify-content:center;text-align:center;margin:0;padding:20px}}a{{color:#e8c97a}}</style>
</head><body><div><p>Abriendo <b>{e(nom)}</b> en el menú de {e(local)}…</p>
<p><a href="{e(destino)}">Ver el producto</a></p><p style="font-size:12px;color:#8d867a">{RH}</p></div>
<script>location.replace({json.dumps(destino).replace('<', '\\u003c')});</script></body></html>
'''
        open(os.path.join(carpeta, 'index.html'), 'w', encoding='utf-8').write(pagina)
        urls.append(url)

# sitemap con el menú y cada producto
hoy = date.today().isoformat()
sm = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
      f'  <url><loc>{BASE}</loc><lastmod>{hoy}</lastmod><changefreq>daily</changefreq><priority>1.0</priority></url>']
for slug in menus:
    if slug != DEF_SLUG:
        sm.append(f'  <url><loc>{BASE}?m={html.escape(seguro(slug).lower())}</loc><lastmod>{hoy}</lastmod><changefreq>daily</changefreq><priority>0.8</priority></url>')
for u in urls:
    sm.append(f'  <url><loc>{html.escape(u)}</loc><lastmod>{hoy}</lastmod><changefreq>weekly</changefreq><priority>0.6</priority></url>')
sm.append('</urlset>')
open(os.path.join(SITIO, 'sitemap.xml'), 'w', encoding='utf-8').write('\n'.join(sm) + '\n')
print(f'{len(urls)} páginas de producto en {len(menus)} menú(s)')
