"""Build the site into public/ (what Vercel serves).
Needs: npm install (pulls jsPDF, autotable and supabase-js), then: python3 build.py"""
import pathlib, shutil
P = pathlib.Path(__file__).parent
nm = P / "node_modules"
libs = "\n".join((nm / f).read_text() for f in [
    "jspdf/dist/jspdf.umd.min.js",
    "jspdf-autotable/dist/jspdf.plugin.autotable.min.js",
    "@supabase/supabase-js/dist/umd/supabase.js",
]).replace("</script", "<\\/script")
out = (P / "src/app.html").read_text().replace("/*__LIBS__*/", libs)
pub = P / "public"
pub.mkdir(exist_ok=True)
(pub / "index.html").write_text(out)
for f in (P / "src").iterdir():
    if f.name != "app.html":
        shutil.copy(f, pub / f.name)
print("public/index.html", len(out), "bytes")
