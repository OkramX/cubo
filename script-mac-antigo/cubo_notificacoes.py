#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Cubo — reencaminha as notificações do macOS para o cubo do escritório.

Lê (só em modo de leitura) a base de dados do Centro de Notificações do
macOS e envia ao cubo, pela rede local, a app e o remetente de cada
notificação nova. Precisa de "Acesso Total ao Disco".

Uso:
  python3 cubo_notificacoes.py                # corre em contínuo
  python3 cubo_notificacoes.py --verificar    # testa o acesso e a ligação ao cubo
  python3 cubo_notificacoes.py --listar-apps  # mostra as apps que enviam notificações
  python3 cubo_notificacoes.py --teste        # envia uma notificação de teste
  python3 cubo_notificacoes.py --limpar       # põe o contador do cubo a zero

Compatível com o Python 3.9 que vem com as ferramentas de linha de comandos da Apple.
"""
import argparse
import json
import logging
import os
import plistlib
import re
import sqlite3
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

CONFIG_DEFAULT_PATH = os.path.expanduser("~/Library/Application Support/Cubo/config.json")

CONFIG_PADRAO = {
    "cubo_url": "http://cubo.local",
    "token": "troca-isto-por-um-codigo-teu",
    "intervalo_segundos": 2,
    "todas_as_apps": False,
    "apps": {
        "com.apple.mail": "Mail",
        "com.microsoft.outlook": "Outlook",
        "com.microsoft.teams2": "Teams",
        "com.apple.ical": "Calendario",
        "net.whatsapp.whatsapp": "WhatsApp",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.google.chrome": "Chrome",
    },
    "apps_ignoradas": [],
    "mostrar_titulo": True,
    "mostrar_subtitulo": False,
    "mostrar_texto": False,
    "codigos_verificacao": "esconder",
}

RE_CODIGO_NUM = re.compile(r"(?<!\d)\d{4,8}(?!\d)")
RE_CODIGO_PAL = re.compile(
    r"c[oó]digo|code|verifica|autentica|otp|\bpin\b|2fa|senha|palavra-passe|password",
    re.IGNORECASE,
)

log = logging.getLogger("cubo")


# ---------------------------------------------------------------------------
#  Configuração
# ---------------------------------------------------------------------------
def carregar_config(caminho):
    cfg = json.loads(json.dumps(CONFIG_PADRAO))
    if os.path.exists(caminho):
        with open(caminho, "r", encoding="utf-8") as f:
            cfg.update(json.load(f))
    else:
        os.makedirs(os.path.dirname(caminho), exist_ok=True)
        with open(caminho, "w", encoding="utf-8") as f:
            json.dump(CONFIG_PADRAO, f, indent=2, ensure_ascii=False)
        log.warning("Criei %s com valores por omissão. Põe lá o teu token.", caminho)
    if cfg["token"] == CONFIG_PADRAO["token"]:
        log.warning("O token ainda é o de exemplo. Muda-o no config.json e no config.h do cubo.")
    return cfg


# ---------------------------------------------------------------------------
#  Base de dados do Centro de Notificações
# ---------------------------------------------------------------------------
def caminhos_bd():
    caminhos = [os.path.expanduser(
        "~/Library/Group Containers/group.com.apple.usernoted/db2/db")]  # macOS 15+
    try:
        d = subprocess.check_output(["getconf", "DARWIN_USER_DIR"], text=True).strip()
        caminhos.append(os.path.join(d, "com.apple.notificationcenter/db2/db"))  # macOS <= 14
    except Exception:
        pass
    return caminhos


def abrir_bd(caminho_forcado=None):
    erros = []
    for p in ([caminho_forcado] if caminho_forcado else caminhos_bd()):
        try:
            uri = "file:{}?mode=ro".format(urllib.parse.quote(p))
            con = sqlite3.connect(uri, uri=True, timeout=5)
            verificar_esquema(con)
            return con, p
        except (sqlite3.Error, RuntimeError, OSError) as e:
            erros.append("{}: {}".format(p, e))
    raise PermissionError(
        "Não consegui ler a base de dados das notificações.\n  "
        + "\n  ".join(erros)
        + "\nSe o erro for 'unable to open' ou 'authorization denied', falta dar "
        "Acesso Total ao Disco ao Python (vê o LEIA-ME)."
    )


def verificar_esquema(con):
    def colunas(tabela):
        return {r[1] for r in con.execute("PRAGMA table_info({})".format(tabela))}

    falta = ({"rec_id", "app_id", "data"} - colunas("record")) | \
            ({"app_id", "identifier"} - colunas("app"))
    if falta:
        raise RuntimeError(
            "A estrutura da base de dados mudou (faltam: {}). "
            "Provavelmente uma atualização do macOS; o script tem de ser ajustado."
            .format(", ".join(sorted(falta))))


def max_rec_id(con):
    return con.execute("SELECT COALESCE(MAX(rec_id), 0) FROM record").fetchone()[0]


def decodificar(blob):
    try:
        d = plistlib.loads(bytes(blob))
    except Exception:
        return None
    req = d.get("req") or {}

    def campo(k):
        v = req.get(k)
        return v.strip() if isinstance(v, str) else ""

    return {"titulo": campo("titl"), "subtitulo": campo("subt"), "texto": campo("body")}


# ---------------------------------------------------------------------------
#  Preparação do que vai para o ecrã
# ---------------------------------------------------------------------------
def ascii_limpo(s):
    s = (s or "").replace("€", "EUR")
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode("ascii")
    return re.sub(r"\s+", " ", s).strip()


def nome_amigavel(ident):
    parte = (ident or "app").split(".")[-1]
    return parte[:1].upper() + parte[1:]


def parece_codigo(texto):
    return bool(RE_CODIGO_NUM.search(texto) and RE_CODIGO_PAL.search(texto))


def preparar(ident, info, cfg):
    ident_l = (ident or "").lower()
    if ident_l in {a.lower() for a in cfg.get("apps_ignoradas", [])}:
        return None
    apps = {k.lower(): v for k, v in cfg["apps"].items()}
    if ident_l in apps:
        nome = apps[ident_l]
    elif cfg["todas_as_apps"]:
        nome = nome_amigavel(ident)
    else:
        return None

    titulo = info["titulo"] if cfg["mostrar_titulo"] else ""
    partes = []
    if cfg["mostrar_subtitulo"] and info["subtitulo"]:
        partes.append(info["subtitulo"])
    if cfg["mostrar_texto"] and info["texto"]:
        partes.append(info["texto"])
    texto = " - ".join(partes)

    tudo = " ".join([info["titulo"], info["subtitulo"], info["texto"]])
    if parece_codigo(tudo):
        modo = cfg.get("codigos_verificacao", "esconder")
        if modo == "ignorar":
            return None
        if modo == "esconder":
            titulo = RE_CODIGO_NUM.sub("****", titulo)
            texto = "(codigo de verificacao oculto)"

    return {"app": ascii_limpo(nome), "titulo": ascii_limpo(titulo), "texto": ascii_limpo(texto)}


# ---------------------------------------------------------------------------
#  Comunicação com o cubo
# ---------------------------------------------------------------------------
def pedir(cfg, caminho, dados=None, metodo="POST"):
    url = cfg["cubo_url"].rstrip("/") + caminho
    corpo = json.dumps(dados or {}).encode("utf-8") if metodo == "POST" else None
    req = urllib.request.Request(url, data=corpo, method=metodo, headers={
        "Content-Type": "application/json", "X-Token": cfg["token"]})
    with urllib.request.urlopen(req, timeout=4) as r:
        return r.status, r.read().decode("utf-8", "replace")


def enviar(cfg, dados):
    for tentativa in range(1, 6):
        try:
            estado, _ = pedir(cfg, "/notify", dados)
            if estado == 200:
                return True
        except urllib.error.HTTPError as e:
            if e.code == 401:
                log.error("O cubo recusou o token. Confirma que é igual no config.json e no config.h.")
                return False
            log.warning("Erro HTTP %s ao enviar (tentativa %d)", e.code, tentativa)
        except Exception as e:
            log.warning("Cubo inacessível (%s), tentativa %d", e, tentativa)
        time.sleep(min(2 * tentativa, 8))
    return False


# ---------------------------------------------------------------------------
#  Comandos
# ---------------------------------------------------------------------------
def cmd_listar_apps(con):
    linhas = con.execute(
        "SELECT a.identifier, COUNT(*) FROM record r JOIN app a ON a.app_id = r.app_id "
        "GROUP BY a.identifier ORDER BY COUNT(*) DESC").fetchall()
    print("Apps com notificações guardadas (identificador -> quantidade):")
    for ident, n in linhas:
        print("  {:45s} {}".format(ident, n))
    print("\nCopia os identificadores que queres para \"apps\" no config.json.")


def cmd_verificar(cfg, bd):
    ok = True
    try:
        con, p = abrir_bd(bd)
        n = con.execute("SELECT COUNT(*) FROM record").fetchone()[0]
        print("[OK] Base de dados lida: {} ({} notificações guardadas)".format(p, n))
    except PermissionError as e:
        print("[ERRO] " + str(e))
        ok = False
    try:
        estado, corpo = pedir(cfg, "/estado", metodo="GET")
        print("[OK] Cubo responde em {}: {}".format(cfg["cubo_url"], corpo))
    except Exception as e:
        print("[ERRO] Cubo não responde em {} ({})".format(cfg["cubo_url"], e))
        print("       Se 'cubo.local' não funcionar, põe o IP do cubo em cubo_url.")
        ok = False
    return ok


def correr(cfg, bd):
    con = None
    ultimo = None
    intervalo = max(1, float(cfg.get("intervalo_segundos", 2)))
    while True:
        try:
            if con is None:
                con, p = abrir_bd(bd)
                atual = max_rec_id(con)
                if ultimo is None:
                    ultimo = atual          # não reenvia notificações antigas
                log.info("A vigiar %s (a partir do registo %s)", p, ultimo)

            atual = max_rec_id(con)
            if atual < ultimo:              # o macOS limpou a base de dados
                ultimo = atual

            linhas = con.execute(
                "SELECT r.rec_id, a.identifier, r.data FROM record r "
                "LEFT JOIN app a ON a.app_id = r.app_id "
                "WHERE r.rec_id > ? ORDER BY r.rec_id", (ultimo,)).fetchall()
            for rec_id, ident, blob in linhas:
                ultimo = max(ultimo, rec_id)
                info = decodificar(blob)
                if not info:
                    continue
                dados = preparar(ident, info, cfg)
                if dados and enviar(cfg, dados):
                    log.info("Enviado: %s", dados["app"])   # o conteúdo não vai para o log
            time.sleep(intervalo)
        except PermissionError as e:
            log.error("%s\nNova tentativa dentro de 60 s.", e)
            con = None
            time.sleep(60)
        except sqlite3.Error as e:
            log.warning("Erro na base de dados (%s); a reabrir.", e)
            try:
                if con is not None:
                    con.close()
            except Exception:
                pass
            con = None
            time.sleep(5)


def main():
    ap = argparse.ArgumentParser(description="Envia as notificações do macOS para o cubo.")
    ap.add_argument("--config", default=CONFIG_DEFAULT_PATH)
    ap.add_argument("--bd", help="caminho alternativo da base de dados (para testes)")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--verificar", action="store_true")
    g.add_argument("--listar-apps", action="store_true")
    g.add_argument("--teste", action="store_true")
    g.add_argument("--limpar", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                        datefmt="%Y-%m-%d %H:%M:%S")
    cfg = carregar_config(args.config)

    if args.verificar:
        sys.exit(0 if cmd_verificar(cfg, args.bd) else 1)
    if args.listar_apps:
        con, _ = abrir_bd(args.bd)
        cmd_listar_apps(con)
        return
    if args.teste:
        ok = enviar(cfg, {"app": "Teste", "titulo": "Ola", "texto": "O cubo esta a funcionar"})
        print("Enviado." if ok else "Falhou (vê os avisos acima).")
        sys.exit(0 if ok else 1)
    if args.limpar:
        try:
            pedir(cfg, "/limpar")
            print("Contador a zero.")
        except Exception as e:
            print("Falhou: {}".format(e))
            sys.exit(1)
        return
    correr(cfg, args.bd)


if __name__ == "__main__":
    main()
