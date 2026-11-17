// =====================================================================
//  Cubo de notificações — firmware para ESP8266 + ST7789 240x240
//  (GeekMagic SmallTV / "Smart Weather Clock" e clones)
//
//  - Relógio com data em português
//  - Recebe notificações por HTTP (POST /notify) vindas do Mac
//  - Alerta: mostra a app e o remetente e pisca a retroiluminação
//  - Contador de notificações recentes
//  - Configuração de Wi-Fi por portal (rede "Cubo-Setup")
//  - Atualizações sem cabo: ArduinoOTA e página /update
// =====================================================================
#include <Arduino.h>
#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266mDNS.h>
#include <ESP8266HTTPUpdateServer.h>
#include <ArduinoOTA.h>
#include <WiFiManager.h>
#include <ArduinoJson.h>
#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <EEPROM.h>
#include <time.h>
#include "config.h"
#include "icones.h"

#define FW_VERSAO "1.5.1"

// ---- Ecrã -------------------------------------------------------------
Adafruit_ST7789 tft(-1, PIN_TFT_DC, PIN_TFT_RST);   // sem CS
const int16_t LARG = 240;

const uint16_t COR_FUNDO    = ST77XX_BLACK;
const uint16_t COR_TEXTO    = ST77XX_WHITE;
const uint16_t COR_SUAVE    = 0x9CD3;   // cinzento
const uint16_t COR_DESTAQUE = 0xFEA0;   // amarelo-torrado (combina com a caixa)
const uint16_t COR_ERRO     = 0xF800;

// ---- Rede -------------------------------------------------------------
ESP8266WebServer server(80);
ESP8266HTTPUpdateServer httpUpdater;

// ---- Estado -----------------------------------------------------------
struct Alerta { String app; String titulo; String texto; };
const uint8_t FILA_MAX = 6;
Alerta  fila[FILA_MAX];
uint8_t filaInicio = 0, filaTam = 0;

enum Ecra { ECRA_RELOGIO, ECRA_ALERTA };
Ecra     ecra = ECRA_RELOGIO;
bool     redesenharTudo = true;
uint32_t alertaDesde = 0;
uint16_t naoLidas = 0;
String   ultimaApp, ultimoRemetente;   // para o lembrete no relógio

// Resumo do dia enviado pela app Cubo do Mac (POST /resumo)
struct Resumo {
  String   evento;            // próximo evento (vazio = nenhum)
  uint32_t inicio = 0, fim = 0;   // hora Unix
  int      tarefas = -1;      // tarefas por fazer hoje (-1 = desconhecido)
  uint32_t focoAte = 0;      // modo Concentração até esta hora Unix (0 = desligado)
  uint32_t recebidoMs = 0;
  bool     valido = false;
} resumo;
const uint32_t RESUMO_VALIDADE_MS = 30UL * 60000UL;   // some se o Mac deixar de enviar

bool resumoAtivo() {
  return resumo.valido && millis() - resumo.recebidoMs < RESUMO_VALIDADE_MS;
}
uint32_t ultimaNotifMs = 0;
int      ultimoMinuto = -1;
int      brilhoManual = -1;        // -1 = automático (dia/noite)
bool     ultimoWifiOk = true;
String   token = CUBO_TOKEN;           // pode ser mudado no portal de configuração

// =====================================================================
//  Token guardado na flash (definido no portal "Cubo-Setup")
// =====================================================================
const int EE_TAM = 1024, EE_MAGIC = 0xCB, TOKEN_MAX = 64;   // 0..80 token, 128.. redes

void lerToken() {
  EEPROM.begin(EE_TAM);
  if (EEPROM.read(0) == EE_MAGIC) {
    char buf[TOKEN_MAX + 1];
    for (int i = 0; i < TOKEN_MAX; i++) buf[i] = (char)EEPROM.read(1 + i);
    buf[TOKEN_MAX] = 0;
    if (strlen(buf) >= 8) token = String(buf);
  }
  EEPROM.end();
}

void guardarToken(const String& t) {
  if (t.length() < 8) return;          // ignora tokens curtos/vazios
  EEPROM.begin(EE_TAM);
  EEPROM.write(0, EE_MAGIC);
  for (int i = 0; i < TOKEN_MAX; i++) EEPROM.write(1 + i, i < (int)t.length() ? t[i] : 0);
  EEPROM.commit();
  EEPROM.end();
  token = t;
}

// =====================================================================
//  Redes Wi-Fi conhecidas (até 6), para o cubo funcionar em vários sítios
// =====================================================================
const int EE_REDES = 128, EE_REDES_MAGIC = 0xCD, REDES_MAX = 6, SSID_MAX = 32, PASS_MAX = 64;
const int REDE_TAM = SSID_MAX + 1 + PASS_MAX + 1;
struct Rede { String ssid, senha; };
Rede redes[REDES_MAX];
int nRedes = 0;

void lerRedes() {
  nRedes = 0;
  EEPROM.begin(EE_TAM);
  if (EEPROM.read(EE_REDES) == EE_REDES_MAGIC) {
    int n = min((int)EEPROM.read(EE_REDES + 1), REDES_MAX);
    for (int k = 0; k < n; k++) {
      int base = EE_REDES + 2 + k * REDE_TAM;
      char a[SSID_MAX + 1], b[PASS_MAX + 1];
      for (int i = 0; i <= SSID_MAX; i++) a[i] = (char)EEPROM.read(base + i);
      for (int i = 0; i <= PASS_MAX; i++) b[i] = (char)EEPROM.read(base + SSID_MAX + 1 + i);
      a[SSID_MAX] = 0; b[PASS_MAX] = 0;
      if (strlen(a)) { redes[nRedes].ssid = a; redes[nRedes].senha = b; nRedes++; }
    }
  }
  EEPROM.end();
}

void guardarRedes() {
  EEPROM.begin(EE_TAM);
  EEPROM.write(EE_REDES, EE_REDES_MAGIC);
  EEPROM.write(EE_REDES + 1, nRedes);
  for (int k = 0; k < REDES_MAX; k++) {
    int base = EE_REDES + 2 + k * REDE_TAM;
    String a = k < nRedes ? redes[k].ssid : String(), b = k < nRedes ? redes[k].senha : String();
    for (int i = 0; i <= SSID_MAX; i++) EEPROM.write(base + i, i < (int)a.length() ? a[i] : 0);
    for (int i = 0; i <= PASS_MAX; i++) EEPROM.write(base + SSID_MAX + 1 + i, i < (int)b.length() ? b[i] : 0);
  }
  EEPROM.commit();
  EEPROM.end();
}

// Acrescenta (ou atualiza) uma rede; a mais recente fica em primeiro
void lembrarRede(const String& ssid, const String& senha) {
  if (!ssid.length() || ssid.length() > SSID_MAX || senha.length() > PASS_MAX) return;
  for (int k = 0; k < nRedes; k++) {
    if (redes[k].ssid == ssid) {
      if (redes[k].senha == senha && k == 0) return;   // nada mudou
      for (int j = k; j > 0; j--) redes[j] = redes[j - 1];
      redes[0].ssid = ssid; redes[0].senha = senha;
      guardarRedes();
      return;
    }
  }
  int n = min(nRedes + 1, REDES_MAX);
  for (int j = n - 1; j > 0; j--) redes[j] = redes[j - 1];
  redes[0].ssid = ssid; redes[0].senha = senha;
  nRedes = n;
  guardarRedes();
}

bool esquecerRede(const String& ssid) {
  for (int k = 0; k < nRedes; k++) {
    if (redes[k].ssid == ssid) {
      for (int j = k; j < nRedes - 1; j++) redes[j] = redes[j + 1];
      nRedes--;
      guardarRedes();
      return true;
    }
  }
  return false;
}

// Procura as redes à volta e liga-se à conhecida com melhor sinal
bool ligarRedeConhecida(uint32_t esperaMs = 15000) {
  if (nRedes == 0) return false;
  WiFi.mode(WIFI_STA);
  int n = WiFi.scanNetworks();
  int melhor = -1, melhorRssi = -1000;
  for (int i = 0; i < n; i++) {
    for (int k = 0; k < nRedes; k++) {
      if (WiFi.SSID(i) == redes[k].ssid && WiFi.RSSI(i) > melhorRssi) { melhor = k; melhorRssi = WiFi.RSSI(i); }
    }
  }
  WiFi.scanDelete();
  if (melhor < 0) return false;
  WiFi.begin(redes[melhor].ssid.c_str(), redes[melhor].senha.c_str());
  uint32_t t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < esperaMs) delay(200);
  return WiFi.status() == WL_CONNECTED;
}

// =====================================================================
//  Utilitários de texto
// =====================================================================

// Letra base para caracteres UTF-8 de 2 bytes que começam por 0xC3
static char letraC3(uint8_t d) {
  if (d >= 0x80 && d <= 0x85) return 'A';
  if (d == 0x87) return 'C';
  if (d >= 0x88 && d <= 0x8B) return 'E';
  if (d >= 0x8C && d <= 0x8F) return 'I';
  if (d == 0x91) return 'N';
  if (d >= 0x92 && d <= 0x96) return 'O';
  if (d >= 0x99 && d <= 0x9C) return 'U';
  if (d >= 0xA0 && d <= 0xA5) return 'a';
  if (d == 0xA7) return 'c';
  if (d >= 0xA8 && d <= 0xAB) return 'e';
  if (d >= 0xAC && d <= 0xAF) return 'i';
  if (d == 0xB1) return 'n';
  if (d >= 0xB2 && d <= 0xB6) return 'o';
  if (d >= 0xB9 && d <= 0xBC) return 'u';
  return '?';
}

// A fonte do ecrã só tem ASCII: tira acentos, troca símbolos, ignora emoji
String paraAscii(const String& in) {
  String out;
  out.reserve(in.length());
  const size_t n = in.length();
  for (size_t i = 0; i < n; i++) {
    uint8_t c = (uint8_t)in[i];
    if (c < 0x80) {
      if (c == '\n' || c == '\r' || c == '\t') out += ' ';
      else if (c >= 0x20) out += (char)c;
      continue;
    }
    if (c == 0xC3 && i + 1 < n) { out += letraC3((uint8_t)in[++i]); continue; }
    if (c == 0xC2 && i + 1 < n) {
      uint8_t d = (uint8_t)in[++i];
      if (d == 0xBA || d == 0xB0) out += 'o';
      else if (d == 0xAA) out += 'a';
      else if (d == 0xA0) out += ' ';
      continue;
    }
    if (c == 0xE2 && i + 2 < n) {
      uint8_t d = (uint8_t)in[i + 1], e = (uint8_t)in[i + 2];
      i += 2;
      if (d == 0x82 && e == 0xAC) out += "EUR";
      else if (d == 0x80 && (e == 0x9C || e == 0x9D)) out += '"';
      else if (d == 0x80 && (e == 0x98 || e == 0x99)) out += '\'';
      else if (d == 0x80 && (e == 0x93 || e == 0x94)) out += '-';
      else if (d == 0x80 && e == 0xA6) out += "...";
      continue;
    }
    // Outras sequências multibyte (emoji, etc.): salta
    int extra = (c >= 0xF0) ? 3 : (c >= 0xE0) ? 2 : (c >= 0xC0) ? 1 : 0;
    i += extra;
  }
  out.trim();
  return out;
}

// Texto centrado numa linha (fonte base 6x8 multiplicada por "tam")
void centrado(String s, int16_t y, uint8_t tam, uint16_t cor, uint16_t fundo) {
  const int maxChars = LARG / (6 * tam);
  if ((int)s.length() > maxChars) s = s.substring(0, maxChars);
  int16_t w = s.length() * 6 * tam - tam;
  tft.setTextSize(tam);
  tft.setTextColor(cor, fundo);
  tft.setCursor((LARG - w) / 2, y);
  tft.print(s);
}

// Texto com quebra por palavras; devolve o y seguinte
int16_t quebrado(String txt, int16_t x, int16_t y, uint8_t tam, uint16_t cor, uint8_t maxLinhas) {
  tft.setTextSize(tam);
  tft.setTextColor(cor);
  tft.setTextWrap(false);
  const int maxChars = (LARG - 2 * x) / (6 * tam);
  const int16_t altLinha = 8 * tam + 5;
  txt.trim();
  uint8_t linhas = 0;
  while (txt.length() && linhas < maxLinhas) {
    String linha;
    if ((int)txt.length() <= maxChars) {
      linha = txt;
      txt = "";
    } else {
      int corte = txt.lastIndexOf(' ', maxChars);
      if (corte <= 0) corte = maxChars;
      linha = txt.substring(0, corte);
      txt = txt.substring(corte);
      txt.trim();
    }
    if (linhas == maxLinhas - 1 && txt.length()) {
      if ((int)linha.length() > maxChars - 3) linha = linha.substring(0, maxChars - 3);
      linha += "...";
    }
    tft.setCursor(x, y);
    tft.print(linha);
    y += altLinha;
    linhas++;
  }
  return y;
}

// =====================================================================
//  Retroiluminação
// =====================================================================
void definirBrilho(int pct) {
  static int ultimo = -1;
  pct = constrain(pct, 0, 100);
  if (pct == ultimo) return;
  ultimo = pct;
  int v = map(pct, 0, 100, 0, 255);
#if BACKLIGHT_ACTIVE_LOW
  v = 255 - v;
#endif
  analogWrite(PIN_BACKLIGHT, v);
}

bool horaValida() { return time(nullptr) > 1700000000; }

int brilhoAlvo() {
  if (brilhoManual >= 0) return brilhoManual;
  if (!horaValida()) return BRILHO_DIA;
  time_t agora = time(nullptr);
  struct tm t;
  localtime_r(&agora, &t);
  bool noite = (HORA_NOITE_INICIO > HORA_NOITE_FIM)
                 ? (t.tm_hour >= HORA_NOITE_INICIO || t.tm_hour < HORA_NOITE_FIM)
                 : (t.tm_hour >= HORA_NOITE_INICIO && t.tm_hour < HORA_NOITE_FIM);
  return noite ? BRILHO_NOITE : BRILHO_DIA;
}

// =====================================================================
//  Ecrãs
// =====================================================================
void mostrarMensagem(const char* titulo, const String& corpo) {
  tft.fillScreen(COR_FUNDO);
  tft.fillRect(0, 0, LARG, 44, COR_DESTAQUE);
  centrado(titulo, 14, 2, COR_FUNDO, COR_DESTAQUE);
  int16_t y = 70;
  int inicio = 0;
  while (inicio <= (int)corpo.length()) {
    int fim = corpo.indexOf('\n', inicio);
    if (fim < 0) fim = corpo.length();
    centrado(corpo.substring(inicio, fim), y, 2, COR_TEXTO, COR_FUNDO);
    y += 26;
    inicio = fim + 1;
  }
}

const char* DIAS[]  = {"Domingo", "Segunda", "Terca", "Quarta", "Quinta", "Sexta", "Sabado"};
const char* MESES[] = {"jan", "fev", "mar", "abr", "mai", "jun",
                       "jul", "ago", "set", "out", "nov", "dez"};

// Ícone da app: "lado" 64 (tamanho real) ou 32 (metade)
void desenharIcone(const String& app, int16_t x, int16_t y, uint8_t lado) {
  const IconeApp* ic = nullptr;
  for (uint8_t i = 0; i < N_ICONES; i++)
    if (app.equalsIgnoreCase(ICONES[i].nome)) { ic = &ICONES[i]; break; }

  if (ic && ic->px) {
    const uint8_t passo = ICONE_LADO / lado;
    tft.startWrite();
    tft.setAddrWindow(x, y, lado, lado);
    for (uint8_t r = 0; r < lado; r++)
      for (uint8_t c = 0; c < lado; c++)
        tft.SPI_WRITE16(pgm_read_word(&ic->px[(r * passo) * ICONE_LADO + c * passo]));
    tft.endWrite();
    return;
  }
  // Sem imagem: quadrado colorido com a inicial da app
  uint16_t cor = (ic && ic->cor) ? ic->cor : COR_DESTAQUE;
  tft.fillRoundRect(x, y, lado, lado, lado / 5, cor);
  uint8_t tam = lado >= 64 ? 5 : 3;
  String ini = app.length() ? app.substring(0, 1) : String("?");
  ini.toUpperCase();
  tft.setTextSize(tam);
  tft.setTextColor(ST77XX_WHITE);
  tft.setCursor(x + (lado - (6 * tam - tam)) / 2, y + (lado - 7 * tam) / 2);
  tft.print(ini);
}

// =====================================================================
//  Olhos animados (alternam com as horas)
// =====================================================================
const int16_t OLHO_W = 80, OLHO_H = 72, OLHOS_Y = 52;
const int16_t OLHO_X[2] = {36, 124};
const uint32_t OLHOS_DURACAO = 6600;
const uint16_t OLHOS_CORES[] = {0xFEA0, 0x07FF, 0xFB56, 0x87F0, 0xFC60};   // amarelo, ciano, rosa, verde, laranja
const uint16_t COR_BOCHECHA = 0xFB2C;

bool      olhosLigados = OLHOS_ATIVOS;
uint32_t  olhosCadaMs = (uint32_t)OLHOS_CADA_SEGUNDOS * 1000UL;
bool      emOlhos = false;
uint32_t  olhosDesde = 0, proximosOlhos = 15000, ultimoFrameOlhos = 0;
uint8_t   corOlhos = 0;
GFXcanvas16* telaOlho = nullptr;

bool olhosNoEcra() { return emOlhos; }

// Momentos-chave da animação: tempo (ms), altura do olho, olhar x, olhar y, sorriso (0..1)
struct Pose { uint16_t t; float h, gx, gy, feliz; };
const Pose POSES[] = {
  {   0,  4,   0,  0, 0}, { 250,  4,   0,  0, 0}, { 600, 56,   0,  0, 0}, {1500, 56,   0,  0, 0},
  {1800, 56, -14,  0, 0}, {2500, 56, -14,  0, 0}, {2800, 56,  14, -2, 0}, {3500, 56,  14, -2, 0},
  {3700, 56,   0,  0, 0}, {3820,  4,   0,  0, 0}, {3950, 56,   0,  0, 0}, {4300, 56,   0,  0, 1},
  {5300, 56,   0, -3, 1}, {5600, 56,   0,  0, 0}, {5750,  4,   0,  0, 0}, {5900, 56,   0,  0, 0},
  {6300, 56,   0,  0, 0}, {6550,  4,   0,  0, 0}, {6600,  4,   0,  0, 0},
};

float suave(float x) { return x * x * (3 - 2 * x); }

Pose poseEm(uint32_t t) {
  const int n = sizeof(POSES) / sizeof(POSES[0]);
  if (t >= POSES[n - 1].t) return POSES[n - 1];
  for (int i = 0; i < n - 1; i++) {
    if (t < POSES[i + 1].t) {
      const Pose &a = POSES[i], &b = POSES[i + 1];
      float k = suave((float)(t - a.t) / (float)(b.t - a.t));
      return {(uint16_t)t, a.h + (b.h - a.h) * k, a.gx + (b.gx - a.gx) * k,
              a.gy + (b.gy - a.gy) * k, a.feliz + (b.feliz - a.feliz) * k};
    }
  }
  return POSES[0];
}

// Desenha um olho na tela (canvas) e copia-a para o ecrã — sem piscar
void desenharOlho(int lado, const Pose& p, uint16_t cor, uint32_t t) {
  GFXcanvas16& c = *telaOlho;
  c.fillScreen(COR_FUNDO);
  float salto = p.feliz > 0 ? sinf(t / 170.0f) * 2.0f * p.feliz : 0;
  int16_t h = max(4, (int)p.h);
  int16_t w = 52 + (56 - h) / 8;                      // ao piscar fica um pouco mais largo
  int16_t cx = OLHO_W / 2 + (int16_t)p.gx;
  int16_t cy = OLHO_H / 2 + (int16_t)(p.gy + salto) - 4;
  int16_t r = min<int16_t>(18, h / 2);
  c.fillRoundRect(cx - w / 2, cy - h / 2, w, h, r, cor);

  if (h > 24 && p.feliz < 0.5f)                       // brilho no olho
    c.fillCircle(cx + 11, cy - h / 2 + 13, 6, ST77XX_WHITE);

  if (p.feliz > 0.01f) {                              // olhos sorridentes: um arco "^"
    int16_t desce = (int16_t)((1.0f - p.feliz) * 34);
    c.fillCircle(cx, cy + h / 2 + desce, 34, COR_FUNDO);
    if (p.feliz > 0.3f) {                             // bochechas coradas, do lado de fora
      int16_t bx = lado == 0 ? cx - 18 : cx + 18;
      c.fillRoundRect(bx - 9, OLHO_H - 14, 18, 8, 4, COR_BOCHECHA);
    }
  }
  tft.drawRGBBitmap(OLHO_X[lado], OLHOS_Y, c.getBuffer(), OLHO_W, OLHO_H);
}

void comecarOlhos(uint32_t agora) {
  telaOlho = new GFXcanvas16(OLHO_W, OLHO_H);
  if (!telaOlho || !telaOlho->getBuffer()) {           // sem memória: tenta mais tarde
    delete telaOlho; telaOlho = nullptr;
    proximosOlhos = agora + olhosCadaMs;
    return;
  }
  emOlhos = true;
  olhosDesde = agora;
  ultimoFrameOlhos = 0;
}

void terminarOlhos(uint32_t agora) {
  delete telaOlho; telaOlho = nullptr;
  emOlhos = false;
  corOlhos = (corOlhos + 1) % (sizeof(OLHOS_CORES) / sizeof(OLHOS_CORES[0]));
  proximosOlhos = agora + olhosCadaMs;
  tft.fillRect(0, OLHOS_Y - 2, LARG, OLHO_H + 4, COR_FUNDO);
  ultimoMinuto = -1;                                  // volta a desenhar as horas
}

void animarOlhos(uint32_t agora) {
  if (agora - ultimoFrameOlhos < 33) return;          // ~30 imagens por segundo
  ultimoFrameOlhos = agora;
  uint32_t t = agora - olhosDesde;
  if (t >= OLHOS_DURACAO) { terminarOlhos(agora); return; }
  if (t < 250) {                                      // pálpebras a fechar sobre as horas
    int16_t k = (int16_t)(t * 30 / 250);
    tft.fillRect(0, 60, LARG, k, COR_FUNDO);
    tft.fillRect(0, 120 - k, LARG, k, COR_FUNDO);
    return;
  }
  Pose p = poseEm(t);
  uint16_t cor = OLHOS_CORES[corOlhos];
  desenharOlho(0, p, cor, t);
  desenharOlho(1, p, cor, t);
}

void desenharRelogio(bool tudo) {
  if (tudo) tft.fillScreen(COR_FUNDO);

  time_t agora = time(nullptr);
  struct tm t;
  localtime_r(&agora, &t);
  bool ok = horaValida();

  // Hora grande
  char hhmm[6];
  if (ok) snprintf(hhmm, sizeof(hhmm), "%02d:%02d", t.tm_hour, t.tm_min);
  else    strcpy(hhmm, "--:--");
  if (!olhosNoEcra()) centrado(hhmm, 62, 7, COR_TEXTO, COR_FUNDO);

  // Data
  tft.fillRect(0, 128, LARG, 20, COR_FUNDO);
  if (ok) {
    char data[24];
    snprintf(data, sizeof(data), "%s, %d %s", DIAS[t.tm_wday], t.tm_mday, MESES[t.tm_mon]);
    centrado(data, 130, 2, COR_SUAVE, COR_FUNDO);
  } else {
    centrado("a acertar a hora", 130, 2, COR_SUAVE, COR_FUNDO);
  }

  // Estado do Wi-Fi (só aparece se houver problema)
  // ...ou, em vez disso, as tarefas que faltam hoje
  tft.fillRect(0, 8, LARG, 18, COR_FUNDO);
  if (WiFi.status() != WL_CONNECTED) centrado("sem Wi-Fi", 8, 2, COR_ERRO, COR_FUNDO);
  else if (resumoAtivo() && ok && resumo.focoAte > (uint32_t)agora) {
    time_t tf = resumo.focoAte;
    struct tm tmf;
    localtime_r(&tf, &tmf);
    char linhaFoco[24];
    snprintf(linhaFoco, sizeof(linhaFoco), "Foco ate %02d:%02d", tmf.tm_hour, tmf.tm_min);
    centrado(linhaFoco, 8, 2, 0x7D7F, COR_FUNDO);   // azul-claro
  }
  else if (resumoAtivo() && resumo.tarefas > 0)
    centrado(String(resumo.tarefas) + (resumo.tarefas == 1 ? " tarefa hoje" : " tarefas hoje"),
             8, 2, COR_DESTAQUE, COR_FUNDO);

  // Próximo evento da agenda, por baixo da data
  tft.fillRect(0, 152, LARG, 22, COR_FUNDO);
  if (resumoAtivo() && resumo.evento.length() && ok) {
    uint32_t agora32 = (uint32_t)agora;
    String linha;
    uint16_t cor = COR_TEXTO;
    if (agora32 >= resumo.inicio && agora32 < resumo.fim) {
      linha = "Agora: " + resumo.evento;
      cor = COR_DESTAQUE;
    } else if (agora32 < resumo.inicio) {
      uint32_t falta = (resumo.inicio - agora32 + 59) / 60;
      if (falta <= 60) {
        linha = "Em " + String(falta) + " min: " + resumo.evento;
        cor = COR_DESTAQUE;
      } else {
        time_t ti = resumo.inicio;
        struct tm te;
        localtime_r(&ti, &te);
        char hm[6];
        snprintf(hm, sizeof(hm), "%02d:%02d", te.tm_hour, te.tm_min);
        linha = String(hm) + " " + resumo.evento;
      }
    }
    if (linha.length()) {
      const int maxChars = LARG / 12;
      if ((int)linha.length() > maxChars) linha = linha.substring(0, maxChars - 1) + ".";
      centrado(linha, 155, 2, cor, COR_FUNDO);
    }
  }

  // Contador de notificações recentes
  tft.fillRect(0, 180, LARG, 50, COR_FUNDO);
  if (naoLidas > 0) {
    // Lembrete da última notificação: ícone pequeno + remetente (+N se houver mais)
    desenharIcone(ultimaApp, 12, 188, 32);
    String s = ultimoRemetente.length() ? ultimoRemetente : ultimaApp;
    String extra = naoLidas > 1 ? " +" + String(naoLidas - 1) : String("");
    const int maxChars = (LARG - 56) / 12 - extra.length();
    if ((int)s.length() > maxChars) s = s.substring(0, maxChars - 1) + ".";
    tft.setTextSize(2);
    tft.setTextColor(COR_TEXTO, COR_FUNDO);
    tft.setCursor(52, 197);
    tft.print(s);
    tft.setTextColor(COR_DESTAQUE, COR_FUNDO);
    tft.print(extra);
  }
}

void desenharAlerta(const Alerta& a) {
  tft.fillScreen(COR_FUNDO);
  // Ícone da app em cima, ao centro; nome da app por baixo
  desenharIcone(a.app, (LARG - 64) / 2, 12, 64);
  centrado(a.app.length() ? a.app : String("Notificacao"), 84, 2, COR_SUAVE, COR_FUNDO);

  // Remetente em destaque
  int16_t y = 112;
  if (a.titulo.length()) y = quebrado(a.titulo, 10, y, 3, COR_TEXTO, 2) + 4;
  if (a.texto.length())  quebrado(a.texto, 10, y, 2, COR_SUAVE, 2);

  if (filaTam > 1) {
    String mais = "+" + String(filaTam - 1) + " a seguir";
    centrado(mais, 218, 2, COR_SUAVE, COR_FUNDO);
  }
}

// =====================================================================
//  Fila de alertas
// =====================================================================
void adicionarAlerta(const Alerta& a) {
  if (filaTam == FILA_MAX) {               // fila cheia: descarta o mais antigo
    filaInicio = (filaInicio + 1) % FILA_MAX;
    filaTam--;
  }
  fila[(filaInicio + filaTam) % FILA_MAX] = a;
  filaTam++;
  naoLidas++;
  ultimaNotifMs = millis();
  ultimaApp = a.app;
  ultimoRemetente = a.titulo;
}

void atualizarEcra() {
  const uint32_t agora = millis();

  if (ecra == ECRA_RELOGIO) {
    if (filaTam > 0) {
      if (emOlhos) terminarOlhos(agora);
      ecra = ECRA_ALERTA;
      alertaDesde = agora;
      desenharAlerta(fila[filaInicio]);
      return;
    }
    definirBrilho(brilhoAlvo());

    if (emOlhos) animarOlhos(agora);
    else if (olhosLigados && horaValida() && (int32_t)(agora - proximosOlhos) >= 0) comecarOlhos(agora);

    bool wifiOk = WiFi.status() == WL_CONNECTED;
    time_t t = time(nullptr);
    struct tm tmv;
    localtime_r(&t, &tmv);
    if (redesenharTudo || tmv.tm_min != ultimoMinuto || wifiOk != ultimoWifiOk) {
      desenharRelogio(redesenharTudo);
      redesenharTudo = false;
      ultimoMinuto = tmv.tm_min;
      ultimoWifiOk = wifiOk;
    }
  } else {
    const uint32_t dt = agora - alertaDesde;
    if (dt < PISCAR_MS) definirBrilho(((dt / 300) % 2 == 0) ? 100 : 5);
    else                definirBrilho(max(brilhoAlvo(), 60));

    if (dt >= (uint32_t)ALERTA_SEGUNDOS * 1000UL) {
      filaInicio = (filaInicio + 1) % FILA_MAX;
      filaTam--;
      if (filaTam > 0) {
        alertaDesde = agora;
        desenharAlerta(fila[filaInicio]);
      } else {
        ecra = ECRA_RELOGIO;
        redesenharTudo = true;
      }
    }
  }

  if (NAO_LIDAS_RESET_MIN > 0 && naoLidas > 0 &&
      agora - ultimaNotifMs > (uint32_t)NAO_LIDAS_RESET_MIN * 60000UL) {
    naoLidas = 0;
    if (ecra == ECRA_RELOGIO) redesenharTudo = true;
  }
}

// =====================================================================
//  Servidor HTTP
// =====================================================================
bool autorizado() {
  if (server.header("X-Token") == token || server.arg("token") == token) return true;
  server.send(401, "application/json", "{\"erro\":\"token invalido\"}");
  return false;
}

void responderOk() {
  server.send(200, "application/json",
              String("{\"ok\":true,\"fila\":") + filaTam + ",\"nao_lidas\":" + naoLidas + "}");
}

void handleNotify() {
  if (!autorizado()) return;
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, server.arg("plain"));
  if (err) {
    server.send(400, "application/json", "{\"erro\":\"JSON invalido\"}");
    return;
  }
  Alerta a;
  a.app    = paraAscii(String((const char*)(doc["app"] | ""))).substring(0, 40);
  a.titulo = paraAscii(String((const char*)(doc["titulo"] | ""))).substring(0, 160);
  a.texto  = paraAscii(String((const char*)(doc["texto"] | ""))).substring(0, 240);
  adicionarAlerta(a);
  responderOk();
}

void handleLimpar() {
  if (!autorizado()) return;
  naoLidas = 0;
  if (ecra == ECRA_RELOGIO) redesenharTudo = true;
  responderOk();
}

void handleResumo() {
  if (!autorizado()) return;
  JsonDocument doc;
  if (deserializeJson(doc, server.arg("plain"))) {
    server.send(400, "application/json", "{\"erro\":\"JSON invalido\"}");
    return;
  }
  resumo.evento     = paraAscii(String((const char*)(doc["evento"] | ""))).substring(0, 60);
  resumo.inicio     = doc["inicio"] | 0;
  resumo.fim        = doc["fim"] | 0;
  resumo.tarefas    = doc["tarefas"] | -1;
  resumo.focoAte    = doc["foco_ate"] | 0;
  resumo.recebidoMs = millis();
  resumo.valido     = true;
  ultimoMinuto = -1;   // redesenha só as linhas do relógio, sem piscar o ecrã
  responderOk();
}

void handleBrilho() {
  if (!autorizado()) return;
  int v = server.hasArg("valor") ? server.arg("valor").toInt() : -1;
  brilhoManual = (v < 0) ? -1 : constrain(v, 0, 100);
  responderOk();
}

void handleRedes() {
  if (!autorizado()) return;
  JsonDocument doc;
  JsonArray a = doc["redes"].to<JsonArray>();
  for (int k = 0; k < nRedes; k++) a.add(redes[k].ssid);
  doc["atual"] = WiFi.SSID();
  doc["max"] = REDES_MAX;
  String out;
  serializeJson(doc, out);
  server.send(200, "application/json", out);
}

void handleRedeNova() {
  if (!autorizado()) return;
  JsonDocument doc;
  if (deserializeJson(doc, server.arg("plain"))) {
    server.send(400, "application/json", "{\"erro\":\"JSON invalido\"}");
    return;
  }
  String ssid = doc["ssid"] | "", senha = doc["senha"] | "";
  if (!ssid.length() || ssid.length() > SSID_MAX || senha.length() > PASS_MAX) {
    server.send(400, "application/json", "{\"erro\":\"nome ou palavra-passe invalidos\"}");
    return;
  }
  // a rede atual mantém-se em primeiro
  String atual = WiFi.SSID();
  lembrarRede(ssid, senha);
  if (atual.length() && atual != ssid) lembrarRede(atual, WiFi.psk());
  handleRedes();
}

void handleRedeApagar() {
  if (!autorizado()) return;
  JsonDocument doc;
  deserializeJson(doc, server.arg("plain"));
  esquecerRede(String((const char*)(doc["ssid"] | "")));
  handleRedes();
}

// Troca o código secreto (pede o atual no X-Token); o cubo reinicia a seguir
void handleToken() {
  if (!autorizado()) return;
  JsonDocument doc;
  deserializeJson(doc, server.arg("plain"));
  String novo = doc["novo"] | "";
  if (novo.length() < 8 || novo.length() > (unsigned)TOKEN_MAX) {
    server.send(400, "application/json", "{\"erro\":\"o codigo tem de ter entre 8 e 64 caracteres\"}");
    return;
  }
  guardarToken(novo);
  server.send(200, "application/json", "{\"ok\":true}");
  delay(300);
  ESP.restart();
}

// Liga/desliga os olhos e muda o intervalo: POST /olhos {"ativo":true,"cada":20}
void handleOlhos() {
  if (!autorizado()) return;
  JsonDocument doc;
  deserializeJson(doc, server.arg("plain"));
  if (doc["ativo"].is<bool>()) olhosLigados = doc["ativo"];
  if (doc["cada"].is<int>()) olhosCadaMs = (uint32_t)constrain((int)doc["cada"], 5, 3600) * 1000UL;
  if (!olhosLigados && emOlhos) terminarOlhos(millis());
  proximosOlhos = millis() + 2000;
  server.send(200, "application/json", String("{\"ok\":true,\"ativo\":") + (olhosLigados ? "true" : "false") +
              ",\"cada\":" + String(olhosCadaMs / 1000) + "}");
}

void handleEsquecerWifi() {
  if (!autorizado()) return;
  server.send(200, "application/json", "{\"ok\":true}");
  delay(300);
  WiFiManager wm;
  wm.resetSettings();
  ESP.restart();
}

void handleEstado() {
  String j = "{";
  j += "\"versao\":\"" FW_VERSAO "\",";
  j += "\"ip\":\"" + WiFi.localIP().toString() + "\",";
  j += "\"rssi\":" + String(WiFi.RSSI()) + ",";
  j += "\"nao_lidas\":" + String(naoLidas) + ",";
  j += "\"fila\":" + String(filaTam) + ",";
  j += "\"hora_ok\":" + String(horaValida() ? "true" : "false") + ",";
  j += "\"uptime_s\":" + String(millis() / 1000) + ",";
  j += "\"memoria_livre\":" + String(ESP.getFreeHeap());
  j += "}";
  server.send(200, "application/json", j);
}

void handleRaiz() {
  String h = F("<!doctype html><html lang='pt'><meta charset='utf-8'>"
               "<meta name='viewport' content='width=device-width,initial-scale=1'>"
               "<title>Cubo</title><style>body{font-family:-apple-system,sans-serif;"
               "max-width:520px;margin:2em auto;padding:0 1em}code{background:#eee;padding:2px 4px}"
               "</style><h1>Cubo de notificações</h1>");
  h += "<p>Versão " FW_VERSAO " · IP " + WiFi.localIP().toString() +
       " · notificações recentes: " + String(naoLidas) + "</p>";
  h += F("<p>Endpoints: <code>POST /notify</code>, <code>POST /limpar</code>, "
         "<code>POST /brilho?valor=0-100</code> (-1 = automático), "
         "<code>GET /estado</code>, <code>/update</code> (atualizar firmware).</p>"
         "<p>Todos os POST exigem o cabeçalho <code>X-Token</code>.</p></html>");
  server.send(200, "text/html; charset=utf-8", h);
}

// =====================================================================
//  Arranque
// =====================================================================
void setup() {
  Serial.begin(115200);
  Serial.println();
  Serial.println(F("Cubo de notificacoes " FW_VERSAO));

  pinMode(PIN_BACKLIGHT, OUTPUT);
  analogWriteRange(255);
  analogWriteFreq(1000);
  definirBrilho(BRILHO_DIA);

  SPI.begin();
  tft.init(240, 240, TFT_SPI_MODE);
  tft.setSPISpeed(TFT_SPI_HZ);
  tft.setRotation(TFT_ROTATION);
  tft.invertDisplay(TFT_INVERT);
  mostrarMensagem("Cubo", "a ligar ao Wi-Fi...");

  lerToken();
  lerRedes();

  // Wi-Fi: se não houver rede guardada, abre o portal de configuração,
  // onde também se define o token (código secreto partilhado com o Mac)
  WiFiManager wm;
  WiFiManagerParameter campoToken("token", "Codigo secreto (igual ao do Mac, min. 8 caracteres)", "", TOKEN_MAX);
  wm.addParameter(&campoToken);
  static bool guardarParametros = false;
  wm.setSaveConfigCallback([]() { guardarParametros = true; });
  wm.setHostname(CUBO_HOSTNAME);
  wm.setConfigPortalTimeout(300);
  wm.setAPCallback([](WiFiManager*) {
    mostrarMensagem("Configurar Wi-Fi", "Liga-te a rede\n" CUBO_AP_NOME "\ne abre\n192.168.4.1");
  });
  bool ligado = ligarRedeConhecida();
  if (!ligado && !wm.autoConnect(CUBO_AP_NOME)) {
    mostrarMensagem("Sem Wi-Fi", "a reiniciar...");
    delay(2000);
    ESP.restart();
  }
  lembrarRede(WiFi.SSID(), WiFi.psk());   // a rede atual fica sempre guardada

  if (guardarParametros) guardarToken(String(campoToken.getValue()));
  Serial.println(token == CUBO_TOKEN ? F("Token: o do config.h") : F("Token: definido no portal"));

  configTime(TZ_INFO, "pt.pool.ntp.org", "pool.ntp.org");

  if (MDNS.begin(CUBO_HOSTNAME)) MDNS.addService("http", "tcp", 80);

  ArduinoOTA.setHostname(CUBO_HOSTNAME);
  ArduinoOTA.setPassword(token.c_str());
  ArduinoOTA.onStart([]() { mostrarMensagem("Atualizar", "a receber firmware\nnao desligues"); });
  ArduinoOTA.begin();

  server.collectHeaders("X-Token");
  server.on("/", HTTP_GET, handleRaiz);
  server.on("/estado", HTTP_GET, handleEstado);
  server.on("/notify", HTTP_POST, handleNotify);
  server.on("/limpar", HTTP_POST, handleLimpar);
  server.on("/brilho", HTTP_POST, handleBrilho);
  server.on("/resumo", HTTP_POST, handleResumo);
  server.on("/esquecer-wifi", HTTP_POST, handleEsquecerWifi);
  server.on("/redes", HTTP_GET, handleRedes);
  server.on("/redes", HTTP_POST, handleRedeNova);
  server.on("/redes/apagar", HTTP_POST, handleRedeApagar);
  server.on("/token", HTTP_POST, handleToken);
  server.on("/olhos", HTTP_POST, handleOlhos);
  httpUpdater.setup(&server, "/update", "admin", token);
  server.begin();

  mostrarMensagem("Ligado", WiFi.localIP().toString() + "\n" CUBO_HOSTNAME ".local");
  Serial.print(F("IP: "));
  Serial.println(WiFi.localIP());
  delay(4000);
  redesenharTudo = true;
}

// Se o Wi-Fi cair (ex.: o cubo mudou de sítio), tenta as outras redes conhecidas;
// ao fim de 5 minutos sem rede reinicia (e abre o portal "Cubo-Setup" se nenhuma estiver à vista)
void vigiarWifi() {
  static uint32_t semRedeDesde = 0, ultimaTentativa = 0;
  static bool estavaLigado = true;
  bool ligado = WiFi.status() == WL_CONNECTED;
  uint32_t agora = millis();
  if (ligado) {
    if (!estavaLigado) {            // voltou: pode ser outra rede, refaz o nome cubo.local
      MDNS.end();
      if (MDNS.begin(CUBO_HOSTNAME)) MDNS.addService("http", "tcp", 80);
      lembrarRede(WiFi.SSID(), WiFi.psk());
      redesenharTudo = true;
    }
    semRedeDesde = 0;
  } else {
    if (!semRedeDesde) semRedeDesde = agora;
    if (agora - semRedeDesde > 30000 && agora - ultimaTentativa > 60000) {
      ultimaTentativa = agora;
      ligarRedeConhecida(12000);
    }
    if (agora - semRedeDesde > 5UL * 60000UL) ESP.restart();
  }
  estavaLigado = ligado;
}

void loop() {
  vigiarWifi();
  server.handleClient();
  MDNS.update();
  ArduinoOTA.handle();
  atualizarEcra();
  delay(2);
}
