from pathlib import Path
import re, socket
root = Path(__file__).resolve().parent
ip = input("IP do seu PC na rede (Enter para detectar automaticamente): ").strip()
if not ip:
    sk = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sk.connect(("192.0.2.1", 80))
        ip = sk.getsockname()[0]
    except OSError:
        ip = socket.gethostbyname(socket.gethostname())
    finally:
        sk.close()
print("IP escolhido:", ip)
source = (root / "ayzemenu.lua").read_text(encoding="utf-8")
updated, count = re.subn(r'local API_BASE = "http://[^"\n]+"', f'local API_BASE = "http://{ip}:8080"', source, count=1)
if count != 1:
    raise RuntimeError("Nao foi possivel localizar API_BASE")
out = root / "ayzemenu_IP_LOCAL.lua"
out.write_text(updated, encoding="utf-8")
print("Lua pronto:", out.name)
print("Se testar no mesmo PC, o ayzemenu.lua original tambem funciona.")
