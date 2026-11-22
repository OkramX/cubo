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

#define FW_VERSAO "1.8.0"

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
struct Alerta { String app; String titulo; String texto; bool vip = false; };
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
  uint32_t focoDesde = 0;    // quando começou (para o anel)
  String   treino, forma;    // treino planeado para hoje e forma (vindos da OkramX)
  String   tempo;            // ex.: "18C  12/21"
  String   tempoIcone;       // sol, lua, nuvem, chuva, trovoada, neve, nevoeiro
  String   focoNome;         // texto do anel azul (ex.: "Em reuniao"); vazio = "Concentracao"
  uint32_t fimDia = 0;       // hora Unix do fim do dia de trabalho (0 = desligado)
  uint8_t  humor = 0;        // olhos: 0 normal, 1 contentes, 2 com sono, 3 preocupados
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
uint32_t ultimoCaboMs = 0;          // último pedido recebido pelo cabo USB
bool caboAtivo() { return ultimoCaboMs && millis() - ultimoCaboMs < 120000UL; }
void servirSerie();
void desenharTempo(const String& ic, int16_t x, int16_t y);
void desenharLinhaTreino();
void atualizarEcra();
bool noArranque = true;             // durante o arranque, um pedido pelo cabo interrompe as tentativas de Wi-Fi
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

// Explica em português porque é que a ligação falhou (estado do ESP e motivo dado pelo router)
uint8_t ultimoMotivoWifi = 0;
const char* motivoWifi(uint8_t s) {
  switch (ultimoMotivoWifi) {
    case 15: case 204: case 23: return "palavra-passe\nerrada";
    case 2: case 202: case 203: return "o router nao\naceita o cubo\n(filtro de MAC?)";
    case 201:                   return "rede nao encontrada\n(so 2,4 GHz)";
  }
  switch (s) {
    case WL_NO_SSID_AVAIL:  return "rede nao encontrada\n(so 2,4 GHz)";
    case WL_WRONG_PASSWORD: return "palavra-passe\nerrada";
    case WL_CONNECT_FAILED: return "o router\nrecusou a ligacao";
    default:                return "o router\nnao respondeu";
  }
}

// Liga a uma rede; se falhar, tenta outra vez em modo 802.11g, que alguns
// routers Wi-Fi 6 (802.11ax) aceitam melhor do ESP8266
bool ligarA(const String& ssid, const String& senha, uint32_t esperaMs, uint8_t nModos = 3) {
  static WiFiEventHandler aoDesligar = WiFi.onStationModeDisconnected([](const WiFiEventStationModeDisconnected& e) {
    ultimoMotivoWifi = e.reason;
    Serial.printf("  router desligou: motivo %d\n", e.reason);
  });
  Serial.printf("  palavra-passe com %d caracteres\n", senha.length());
  WiFi.persistent(false);
  WiFi.setAutoReconnect(false);
  WiFi.disconnect(true);
  delay(200);
  WiFi.mode(WIFI_STA);
  WiFi.setSleepMode(WIFI_NONE_SLEEP);
  int n = WiFi.scanNetworks(false, true);
  int32_t canal = 0; uint8_t bssid[6]; bool temBssid = false;
  for (int i = 0; i < n; i++) {
    if (WiFi.SSID(i) == ssid) {
      if (!temBssid) { canal = WiFi.channel(i); memcpy(bssid, WiFi.BSSID(i), 6); temBssid = true; }
      Serial.printf("  vejo '%s' %s canal %d sinal %d dBm cifra %d\n", ssid.c_str(), WiFi.BSSIDstr(i).c_str(), WiFi.channel(i), WiFi.RSSI(i), WiFi.encryptionType(i));
    }
  }
  if (!temBssid) Serial.printf("  nao vejo '%s' (%d redes a volta)\n", ssid.c_str(), n);
  WiFi.scanDelete();
  static const WiFiPhyMode_t modos[] = {WIFI_PHY_MODE_11N, WIFI_PHY_MODE_11G, WIFI_PHY_MODE_11B};
  static const char* nomes[] = {"11n", "11g", "11b"};
  for (uint8_t m = 0; m < nModos; m++) {
    WiFi.setPhyMode(modos[m]);
    ultimoMotivoWifi = 0;
    if (temBssid) WiFi.begin(ssid.c_str(), senha.c_str(), canal, bssid);
    else WiFi.begin(ssid.c_str(), senha.c_str());
    uint32_t t0 = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - t0 < esperaMs) {
      if (WiFi.status() == WL_WRONG_PASSWORD) break;
      servirSerie();
      if (caboAtivo()) {
        if (noArranque) { WiFi.disconnect(); return false; }   // há cabo: não vale a pena esperar pelo Wi-Fi
        atualizarEcra();                                       // o relógio e os alertas continuam
      }
      delay(50);
    }
    Serial.printf("Wi-Fi '%s' modo %s: estado %d\n", ssid.c_str(), nomes[m], WiFi.status());
    if (WiFi.status() == WL_CONNECTED) { WiFi.setAutoReconnect(true); WiFi.persistent(true); return true; }
    if (WiFi.status() == WL_WRONG_PASSWORD) break;
    WiFi.disconnect();
    delay(300);
  }
  WiFi.setPhyMode(WIFI_PHY_MODE_11N);
  WiFi.setAutoReconnect(true);
  WiFi.persistent(true);
  return false;
}

// Procura as redes à volta e liga-se à conhecida com melhor sinal
bool ligarRedeConhecida(uint32_t esperaMs = 15000, uint8_t nModos = 3) {
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
  return ligarA(redes[melhor].ssid, redes[melhor].senha, esperaMs, nModos);
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
void desenharOlho(int lado, const Pose& p, uint16_t cor, uint32_t t, uint8_t humor) {
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

  if (humor == 3 && h > 20) {                         // preocupados: pálpebra inclinada por fora
    int16_t topo = cy - h / 2, ex = lado == 0 ? cx - w / 2 - 2 : cx + w / 2 + 2, ix = lado == 0 ? cx + w / 2 : cx - w / 2;
    c.fillTriangle(ex, topo - 2, ex, topo + h / 2, ix, topo - 2, COR_FUNDO);
  }
  if (humor == 2 && h > 8)                            // com sono: pálpebra pesada por cima
    c.fillRect(cx - w / 2 - 2, cy - h / 2 - 2, w + 4, h / 2 + 2, COR_FUNDO);

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
  uint8_t humor = resumoAtivo() ? resumo.humor : 0;
  if (humor == 1 && t > 600 && t < 5600) p.feliz = max(p.feliz, 1.0f);    // contentes: sorriem quase sempre
  if (humor == 2) { p.gx *= 0.3f; p.gy += 6; }                             // com sono: olham para baixo
  if (humor == 3) { p.gx *= 1.3f; p.feliz = 0; }                           // preocupados: olham à volta
  uint16_t cor = humor == 2 ? 0x8C71 : OLHOS_CORES[corOlhos];
  desenharOlho(0, p, cor, t, humor);
  desenharOlho(1, p, cor, t, humor);
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
  if (WiFi.status() != WL_CONNECTED && !caboAtivo()) centrado("sem Wi-Fi", 8, 2, COR_ERRO, COR_FUNDO);
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
  } else if (resumoAtivo()) {
    if (resumo.tempo.length()) {
      desenharTempo(resumo.tempoIcone, 14, 184);
      tft.setTextSize(2);
      tft.setTextColor(COR_TEXTO, COR_FUNDO);
      tft.setCursor(48, 190);
      tft.print(resumo.tempo);
    }
    desenharLinhaTreino();
  }
}

// Linha do treino (alterna com a forma de 8 em 8 s)
void desenharLinhaTreino() {
  if (!resumoAtivo() || (!resumo.treino.length() && !resumo.forma.length())) return;
  bool mostrarForma = resumo.forma.length() && (!resumo.treino.length() || (millis() / 8000) % 2);
  String s = mostrarForma ? resumo.forma : resumo.treino;
  const int maxChars = (LARG - 40) / 12;
  if ((int)s.length() > maxChars) s = s.substring(0, maxChars - 1) + ".";
  tft.fillRect(0, 210, LARG, 20, COR_FUNDO);
  // bicicleta pequena
  tft.drawCircle(14, 220, 6, 0x2FE5);
  tft.drawCircle(32, 220, 6, 0x2FE5);
  tft.drawLine(14, 220, 22, 212, 0x2FE5);
  tft.drawLine(22, 212, 32, 220, 0x2FE5);
  tft.drawLine(22, 212, 18, 220, 0x2FE5);
  tft.setTextSize(2);
  tft.setTextColor(mostrarForma ? COR_SUAVE : 0x2FE5, COR_FUNDO);
  tft.setCursor(44, 213);
  tft.print(s);
}

// Ícone do tempo (28x28) desenhado com formas simples
void nuvem(int16_t x, int16_t y, uint16_t cor) {
  tft.fillCircle(x + 9, y + 15, 7, cor);
  tft.fillCircle(x + 17, y + 11, 9, cor);
  tft.fillCircle(x + 23, y + 17, 5, cor);
  tft.fillRect(x + 6, y + 15, 20, 7, cor);
}
void desenharTempo(const String& ic, int16_t x, int16_t y) {
  tft.fillRect(x, y, 30, 30, COR_FUNDO);
  const uint16_t AMARELO = 0xFEA0, CINZA = 0xBDF7, AZUL = 0x5D9F;
  if (ic == "sol") {
    tft.fillCircle(x + 14, y + 14, 7, AMARELO);
    for (int a = 0; a < 360; a += 45) {
      float r = a * 0.0174533f;
      tft.drawLine(x + 14 + cosf(r) * 10, y + 14 + sinf(r) * 10, x + 14 + cosf(r) * 13, y + 14 + sinf(r) * 13, AMARELO);
    }
  } else if (ic == "lua") {
    tft.fillCircle(x + 14, y + 14, 9, AMARELO);
    tft.fillCircle(x + 19, y + 10, 8, COR_FUNDO);
  } else if (ic == "pouco") {
    tft.fillCircle(x + 10, y + 9, 7, AMARELO);
    nuvem(x + 2, y + 4, CINZA);
  } else if (ic == "chuva") {
    nuvem(x, y - 2, CINZA);
    for (int i = 0; i < 3; i++) tft.drawLine(x + 8 + i * 7, y + 22, x + 5 + i * 7, y + 28, AZUL);
  } else if (ic == "trovoada") {
    nuvem(x, y - 2, 0x7BEF);
    tft.drawLine(x + 15, y + 20, x + 11, y + 25, AMARELO);
    tft.drawLine(x + 11, y + 25, x + 16, y + 25, AMARELO);
    tft.drawLine(x + 16, y + 25, x + 12, y + 30, AMARELO);
  } else if (ic == "neve") {
    nuvem(x, y - 2, CINZA);
    for (int i = 0; i < 3; i++) tft.fillCircle(x + 8 + i * 7, y + 25, 2, COR_TEXTO);
  } else if (ic == "nevoeiro") {
    for (int i = 0; i < 4; i++) tft.drawFastHLine(x + 3 + (i % 2) * 3, y + 7 + i * 6, 22, CINZA);
  } else if (ic.length()) {
    nuvem(x, y + 2, CINZA);
  }
}

// =====================================================================
//  Anel: contagem para a reunião e tempo de Concentração
// =====================================================================
enum ModoAnel { ANEL_NENHUM, ANEL_REUNIAO, ANEL_FOCO, ANEL_DIA };
const int16_t ANEL_CX = 120, ANEL_CY = 112, ANEL_RE = 82, ANEL_RI = 70;
const uint16_t COR_ANEL_FUNDO = 0x2124;

ModoAnel modoAnel() {
  if (!resumoAtivo() || !horaValida()) return ANEL_NENHUM;
  uint32_t agora = (uint32_t)time(nullptr);
  if (resumo.evento.length() && resumo.inicio > agora && resumo.inicio - agora <= 600) return ANEL_REUNIAO;
  if (resumo.focoAte > agora) return ANEL_FOCO;
  if (resumo.fimDia > agora && resumo.fimDia - agora <= 3600) return ANEL_DIA;
  return ANEL_NENHUM;
}

// Pinta o anel entre os ângulos a0 e a1 (graus, 0 = em cima, sentido dos ponteiros)
void arco(float a0, float a1, uint16_t cor) {
  for (float a = a0; a < a1; a += 0.6f) {
    float r = (a - 90.0f) * 0.0174533f, c = cosf(r), s = sinf(r);
    tft.drawLine(ANEL_CX + c * ANEL_RI, ANEL_CY + s * ANEL_RI, ANEL_CX + c * ANEL_RE, ANEL_CY + s * ANEL_RE, cor);
  }
}

void desenharAnel(ModoAnel modo, bool tudo) {
  static float anguloAntes = 0;
  static uint16_t corAntes = 0;
  static int restanteAntes = -1;
  static String rotuloAntes;
  uint32_t agora = (uint32_t)time(nullptr);
  uint32_t total, restante;
  uint16_t cor;
  String rotulo;
  if (modo == ANEL_REUNIAO) {
    total = 600;
    restante = resumo.inicio - agora;
    bool pisca = restante <= 60 && (agora % 2);
    cor = restante > 300 ? 0x2FE5 : restante > 60 ? 0xFC60 : (pisca ? 0x6000 : 0xF800);
    rotulo = resumo.evento;
  } else if (modo == ANEL_DIA) {
    total = 3600;
    restante = resumo.fimDia - agora;
    cor = 0xC99F;
    rotulo = "Fim do dia";
  } else {
    restante = resumo.focoAte - agora;
    total = resumo.focoDesde && resumo.focoDesde < resumo.focoAte ? resumo.focoAte - resumo.focoDesde : max<uint32_t>(restante, 3600);
    cor = 0x5D9F;
    rotulo = resumo.focoNome.length() ? resumo.focoNome : String("Concentracao");
  }
  if (restante > total) restante = total;
  float angulo = 360.0f * restante / total;

  if (tudo) {
    tft.fillScreen(COR_FUNDO);
    anguloAntes = 0; corAntes = 0; restanteAntes = -1; rotuloAntes = "";
  }
  if (cor != corAntes || angulo > anguloAntes + 0.5f) {
    arco(0, angulo, cor);
    arco(angulo, 360, COR_ANEL_FUNDO);
  } else if (angulo < anguloAntes) {
    arco(angulo, anguloAntes + 0.6f, COR_ANEL_FUNDO);
  }
  anguloAntes = angulo;
  corAntes = cor;

  // número ao centro: minutos (ou segundos no último minuto da reunião)
  bool segundos = modo == ANEL_REUNIAO && restante < 60;
  int valor = segundos ? restante : (restante + 59) / 60;
  if (valor != restanteAntes || tudo) {
    restanteAntes = valor;
    tft.fillRect(ANEL_CX - 62, ANEL_CY - 34, 124, 70, COR_FUNDO);
    centrado(String(valor), ANEL_CY - 30, valor >= 100 ? 5 : 6, COR_TEXTO, COR_FUNDO);
    centrado(segundos ? "seg" : "min", ANEL_CY + 20, 2, COR_SUAVE, COR_FUNDO);
  }

  // hora atual em cima e nome em baixo
  time_t ta = agora;
  struct tm tmv;
  localtime_r(&ta, &tmv);
  char hhmm[6];
  snprintf(hhmm, sizeof(hhmm), "%02d:%02d", tmv.tm_hour, tmv.tm_min);
  centrado(hhmm, 8, 2, COR_SUAVE, COR_FUNDO);
  if (rotulo != rotuloAntes) {
    rotuloAntes = rotulo;
    tft.fillRect(0, 204, LARG, 20, COR_FUNDO);
    const int maxChars = LARG / 12;
    if ((int)rotulo.length() > maxChars) rotulo = rotulo.substring(0, maxChars - 1) + ".";
    centrado(rotulo, 206, 2, modo == ANEL_REUNIAO ? COR_TEXTO : cor, COR_FUNDO);
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

  if (a.vip) {                                        // pessoa VIP: moldura vermelha
    for (int k = 0; k < 4; k++) tft.drawRect(k, k, LARG - 2 * k, LARG - 2 * k, 0xF800);
  }
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

    // Contagem para a reunião / Concentração: o anel substitui o relógio
    static ModoAnel anelAntes = ANEL_NENHUM;
    static uint32_t segundoAnel = 0;
    ModoAnel anel = modoAnel();
    if (anel != ANEL_NENHUM) {
      if (emOlhos) terminarOlhos(agora);
      uint32_t s = (uint32_t)time(nullptr);
      if (anel != anelAntes || redesenharTudo || s != segundoAnel) {
        desenharAnel(anel, anel != anelAntes || redesenharTudo);
        redesenharTudo = false;
        segundoAnel = s;
      }
      anelAntes = anel;
      return;
    }
    if (anelAntes != ANEL_NENHUM) {          // acabou: volta ao relógio com os olhos a sorrir
      anelAntes = ANEL_NENHUM;
      redesenharTudo = true;
      proximosOlhos = olhosLigados ? agora : 1;   // 1 = olhos uma vez, mesmo desligados
    }
    // a linha do treino alterna com a forma
    static uint32_t trocaTreino = 0;
    if (!emOlhos && naoLidas == 0 && resumoAtivo() && resumo.forma.length() && resumo.treino.length() &&
        agora / 8000 != trocaTreino) {
      trocaTreino = agora / 8000;
      desenharLinhaTreino();
    }

    if (emOlhos) animarOlhos(agora);
    else if (horaValida() && (int32_t)(agora - proximosOlhos) >= 0 && (olhosLigados || proximosOlhos == 1)) comecarOlhos(agora);

    bool wifiOk = WiFi.status() == WL_CONNECTED || caboAtivo();
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
    const bool vip = filaTam > 0 && fila[filaInicio].vip;
    if (dt < (vip ? PISCAR_MS * 3 : PISCAR_MS)) definirBrilho(((dt / (vip ? 180 : 300)) % 2 == 0) ? 100 : 5);
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
// Pedidos chegam por HTTP (Wi-Fi) ou pelo cabo USB (linhas "@/caminho {json}")
bool   pedidoSerie = false;
String corpoSerie;
String corpo() { return pedidoSerie ? corpoSerie : server.arg("plain"); }
void responder(int codigo, const char* tipo, const String& b) {
  if (!pedidoSerie) { server.send(codigo, tipo, b); return; }
  Serial.print(F("\n@R ")); Serial.print(codigo); Serial.print(' '); Serial.println(b);
}

bool autorizado() {
  if (pedidoSerie) return true;          // o cabo USB é ligação física: não pede token
  if (server.header("X-Token") == token || server.arg("token") == token) return true;
  responder(401, "application/json", "{\"erro\":\"token invalido\"}");
  return false;
}

void responderOk() {
  responder(200, "application/json",
              String("{\"ok\":true,\"fila\":") + filaTam + ",\"nao_lidas\":" + naoLidas + "}");
}

void handleNotify() {
  if (!autorizado()) return;
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, corpo());
  if (err) {
    responder(400, "application/json", "{\"erro\":\"JSON invalido\"}");
    return;
  }
  Alerta a;
  a.app    = paraAscii(String((const char*)(doc["app"] | ""))).substring(0, 40);
  a.titulo = paraAscii(String((const char*)(doc["titulo"] | ""))).substring(0, 160);
  a.texto  = paraAscii(String((const char*)(doc["texto"] | ""))).substring(0, 240);
  a.vip    = doc["vip"] | false;
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
  if (deserializeJson(doc, corpo())) {
    responder(400, "application/json", "{\"erro\":\"JSON invalido\"}");
    return;
  }
  resumo.evento     = paraAscii(String((const char*)(doc["evento"] | ""))).substring(0, 60);
  resumo.inicio     = doc["inicio"] | 0;
  resumo.fim        = doc["fim"] | 0;
  resumo.tarefas    = doc["tarefas"] | -1;
  resumo.focoAte    = doc["foco_ate"] | 0;
  resumo.focoDesde  = doc["foco_desde"] | 0;
  resumo.treino     = paraAscii(String((const char*)(doc["treino"] | ""))).substring(0, 40);
  resumo.forma      = paraAscii(String((const char*)(doc["forma"] | ""))).substring(0, 40);
  resumo.tempo      = paraAscii(String((const char*)(doc["tempo"] | ""))).substring(0, 16);
  resumo.tempoIcone = String((const char*)(doc["tempo_icone"] | ""));
  resumo.focoNome   = paraAscii(String((const char*)(doc["foco_nome"] | ""))).substring(0, 20);
  resumo.fimDia     = doc["fim_dia"] | 0;
  resumo.humor      = doc["humor"] | 0;
  resumo.recebidoMs = millis();
  resumo.valido     = true;
  ultimoMinuto = -1;   // redesenha só as linhas do relógio, sem piscar o ecrã
  responderOk();
}

void handleBrilho() {
  if (!autorizado()) return;
  int v = -1;
  if (pedidoSerie) { JsonDocument d; if (!deserializeJson(d, corpoSerie)) v = d["valor"] | -1; }
  else if (server.hasArg("valor")) v = server.arg("valor").toInt();
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
  responder(200, "application/json", out);
}

void handleRedeNova() {
  if (!autorizado()) return;
  JsonDocument doc;
  if (deserializeJson(doc, corpo())) {
    responder(400, "application/json", "{\"erro\":\"JSON invalido\"}");
    return;
  }
  String ssid = doc["ssid"] | "", senha = doc["senha"] | "";
  if (!ssid.length() || ssid.length() > SSID_MAX || senha.length() > PASS_MAX) {
    responder(400, "application/json", "{\"erro\":\"nome ou palavra-passe invalidos\"}");
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
  deserializeJson(doc, corpo());
  esquecerRede(String((const char*)(doc["ssid"] | "")));
  handleRedes();
}

// Troca o código secreto (pede o atual no X-Token); o cubo reinicia a seguir
void handleToken() {
  if (!autorizado()) return;
  JsonDocument doc;
  deserializeJson(doc, corpo());
  String novo = doc["novo"] | "";
  if (novo.length() < 8 || novo.length() > (unsigned)TOKEN_MAX) {
    responder(400, "application/json", "{\"erro\":\"o codigo tem de ter entre 8 e 64 caracteres\"}");
    return;
  }
  guardarToken(novo);
  responder(200, "application/json", "{\"ok\":true}");
  delay(300);
  ESP.restart();
}

// Liga/desliga os olhos e muda o intervalo: POST /olhos {"ativo":true,"cada":20}
void handleOlhos() {
  if (!autorizado()) return;
  JsonDocument doc;
  deserializeJson(doc, corpo());
  if (doc["ativo"].is<bool>()) olhosLigados = doc["ativo"];
  if (doc["cada"].is<int>()) olhosCadaMs = (uint32_t)constrain((int)doc["cada"], 5, 3600) * 1000UL;
  if (!olhosLigados && emOlhos) terminarOlhos(millis());
  proximosOlhos = millis() + 2000;
  responder(200, "application/json", String("{\"ok\":true,\"ativo\":") + (olhosLigados ? "true" : "false") +
              ",\"cada\":" + String(olhosCadaMs / 1000) + "}");
}

void handleEsquecerWifi() {
  if (!autorizado()) return;
  responder(200, "application/json", "{\"ok\":true}");
  delay(300);
  WiFiManager wm;
  wm.resetSettings();
  ESP.restart();
}

void handleEstado() {
  String j = "{";
  j += "\"versao\":\"" FW_VERSAO "\",";
  j += "\"ip\":\"" + WiFi.localIP().toString() + "\",";
  j += "\"wifi\":" + String(WiFi.status() == WL_CONNECTED ? "true" : "false") + ",";
  j += "\"cabo\":" + String(pedidoSerie ? "true" : "false") + ",";
  j += "\"rssi\":" + String(WiFi.RSSI()) + ",";
  j += "\"nao_lidas\":" + String(naoLidas) + ",";
  j += "\"fila\":" + String(filaTam) + ",";
  j += "\"hora_ok\":" + String(horaValida() ? "true" : "false") + ",";
  j += "\"uptime_s\":" + String(millis() / 1000) + ",";
  j += "\"memoria_livre\":" + String(ESP.getFreeHeap());
  j += "}";
  responder(200, "application/json", j);
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
  responder(200, "text/html; charset=utf-8", h);
}

// Acerta o relógio (pelo cabo não há NTP): {"epoch": segundos desde 1970}
void handleHora() {
  JsonDocument doc;
  if (deserializeJson(doc, corpo()) || !doc["epoch"].is<uint32_t>()) { responder(400, "application/json", "{\"erro\":\"epoch\"}"); return; }
  struct timeval tv = { (time_t)doc["epoch"].as<uint32_t>(), 0 };
  settimeofday(&tv, nullptr);
  redesenharTudo = true;
  responderOk();
}

// Lê comandos do cabo USB: uma linha "@/notify {json}", "@/estado", ...
void tratarLinhaSerie(const String& l) {
  if (!l.startsWith("@/")) return;
  int sp = l.indexOf(' ');
  String caminho = sp < 0 ? l.substring(1) : l.substring(1, sp);
  corpoSerie = sp < 0 ? String() : l.substring(sp + 1);
  pedidoSerie = true;
  ultimoCaboMs = millis();
  if      (caminho == "/notify")       handleNotify();
  else if (caminho == "/estado")       handleEstado();
  else if (caminho == "/resumo")       handleResumo();
  else if (caminho == "/limpar")       handleLimpar();
  else if (caminho == "/brilho")       handleBrilho();
  else if (caminho == "/olhos")        handleOlhos();
  else if (caminho == "/hora")         handleHora();
  else if (caminho == "/redes")        corpoSerie.length() ? handleRedeNova() : handleRedes();
  else if (caminho == "/redes/apagar") handleRedeApagar();
  else if (caminho == "/token")        handleToken();
  else responder(404, "application/json", "{\"erro\":\"desconhecido\"}");
  pedidoSerie = false;
  corpoSerie = String();
}

void servirSerie() {
  static String linha;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n') { tratarLinhaSerie(linha); linha = String(); }
    else if (c != '\r' && linha.length() < 2048) linha += c;
  }
}

WiFiManager wm;
WiFiManagerParameter campoToken("token", "Codigo secreto (igual ao do Mac, min. 8 caracteres)", "", TOKEN_MAX);
bool guardarParametros = false;
bool redeAtiva = false;       // servidor HTTP, mDNS e OTA a funcionar
bool portalAberto = false;    // rede "Cubo-Setup" aberta
uint32_t ultimoPortalMs = 0;

// Ligado a um Wi-Fi: liga o servidor, o cubo.local e as atualizações sem fios
void iniciarRede() {
  lembrarRede(WiFi.SSID(), WiFi.psk());   // a rede atual fica sempre guardada
  if (guardarParametros) { guardarToken(String(campoToken.getValue())); guardarParametros = false; }
  static bool primeiraVez = true;
  if (primeiraVez) {
    primeiraVez = false;
    ArduinoOTA.setHostname(CUBO_HOSTNAME);
    ArduinoOTA.setPassword(token.c_str());
    ArduinoOTA.onStart([]() { mostrarMensagem("Atualizar", "a receber firmware\nnao desligues"); });
    ArduinoOTA.begin();
    httpUpdater.setup(&server, "/update", "admin", token);
  }
  MDNS.end();
  if (MDNS.begin(CUBO_HOSTNAME)) MDNS.addService("http", "tcp", 80);
  server.begin();
  redeAtiva = true;
  Serial.print(F("IP: "));
  Serial.println(WiFi.localIP());
  mostrarMensagem("Ligado", WiFi.localIP().toString() + "\n" CUBO_HOSTNAME ".local");
  delay(3000);
  redesenharTudo = true;
}

// Abre a rede "Cubo-Setup" sem bloquear: o relógio e o cabo USB continuam a funcionar
void abrirPortal(bool avisar) {
  if (redeAtiva) { server.stop(); MDNS.end(); redeAtiva = false; }
  wm.startConfigPortal(CUBO_AP_NOME);
  portalAberto = true;
  ultimoPortalMs = millis();
  if (avisar) {
    mostrarMensagem("Sem Wi-Fi", "Liga-te a rede\n" CUBO_AP_NOME "\n(192.168.4.1)\nou usa o cabo USB");
    delay(5000);
  }
  redesenharTudo = true;
}

// =====================================================================
//  Arranque
// =====================================================================
void setup() {
  Serial.setRxBufferSize(2048);
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
  configTime(TZ_INFO, "pt.pool.ntp.org", "pool.ntp.org");   // fuso horário, mesmo sem rede
  Serial.println(token == CUBO_TOKEN ? F("Token: o do config.h") : F("Token: definido no portal"));

  // Portal "Cubo-Setup" (não bloqueia), onde também se define o token
  wm.addParameter(&campoToken);
  wm.setSaveConfigCallback([]() { guardarParametros = true; });
  wm.setPreSaveConfigCallback([]() { mostrarMensagem("A ligar...", "a experimentar\na rede escolhida"); });
  wm.setHostname(CUBO_HOSTNAME);
  wm.setConfigPortalBlocking(false);
  wm.setConfigPortalTimeout(300);
  wm.setConnectTimeout(25);
  wm.setSaveConnectTimeout(30);

  server.collectHeaders("X-Token");
  server.on("/", HTTP_GET, handleRaiz);
  server.on("/estado", HTTP_GET, handleEstado);
  server.on("/notify", HTTP_POST, handleNotify);
  server.on("/limpar", HTTP_POST, handleLimpar);
  server.on("/brilho", HTTP_POST, handleBrilho);
  server.on("/resumo", HTTP_POST, handleResumo);
  server.on("/hora", HTTP_POST, handleHora);
  server.on("/esquecer-wifi", HTTP_POST, handleEsquecerWifi);
  server.on("/redes", HTTP_GET, handleRedes);
  server.on("/redes", HTTP_POST, handleRedeNova);
  server.on("/redes/apagar", HTTP_POST, handleRedeApagar);
  server.on("/token", HTTP_POST, handleToken);
  server.on("/olhos", HTTP_POST, handleOlhos);

  bool ligado = ligarRedeConhecida();
  if (!ligado && !caboAtivo() && wm.getWiFiSSID().length()) {   // a última rede escrita no portal
    mostrarMensagem("A ligar...", wm.getWiFiSSID());
    ligado = ligarA(wm.getWiFiSSID(), wm.getWiFiPass(), 15000);
  }
  noArranque = false;
  if (ligado) iniciarRede();
  else if (caboAtivo()) Serial.println(F("Sem Wi-Fi: a funcionar pelo cabo USB"));
  else {
    if (ultimoMotivoWifi) {
      mostrarMensagem("Nao ligou", String(motivoWifi(WiFi.status())) + "\nMAC " + WiFi.macAddress());
      delay(5000);
    }
    abrirPortal(true);
  }
  redesenharTudo = true;
}

// Se o Wi-Fi cair (ex.: o cubo mudou de sítio), tenta as redes conhecidas de minuto a minuto;
// sem rede há 5 min, abre o portal "Cubo-Setup" (no máximo de 15 em 15 min). Nunca reinicia:
// sem Wi-Fi o cubo continua a receber tudo pelo cabo USB.
void vigiarWifi() {
  static uint32_t semRedeDesde = 0, ultimaTentativa = 0;
  static bool estavaLigado = true;
  bool ligado = WiFi.status() == WL_CONNECTED;
  uint32_t agora = millis();
  if (ligado) {
    if (!redeAtiva) iniciarRede();
    else if (!estavaLigado) {       // voltou: pode ser outra rede, refaz o nome cubo.local
      MDNS.end();
      if (MDNS.begin(CUBO_HOSTNAME)) MDNS.addService("http", "tcp", 80);
      lembrarRede(WiFi.SSID(), WiFi.psk());
      redesenharTudo = true;
    }
    semRedeDesde = 0;
  } else {
    if (!semRedeDesde) semRedeDesde = agora;
    const uint32_t intervalo = caboAtivo() ? 5UL * 60000UL : 60000UL;   // com cabo, tenta com calma
    if (agora - semRedeDesde > 30000 && agora - ultimaTentativa > intervalo) {
      ultimaTentativa = agora;
      ligarRedeConhecida(10000, 1);
    }
    if (!caboAtivo() && agora - semRedeDesde > 5UL * 60000UL && agora - ultimoPortalMs > 15UL * 60000UL) abrirPortal(false);
  }
  estavaLigado = ligado;
}

void loop() {
  servirSerie();
  if (portalAberto) {
    if (wm.process()) { portalAberto = false; iniciarRede(); }          // escolheram uma rede e ligou
    else if (!wm.getConfigPortalActive()) portalAberto = false;          // fechou por tempo
  } else {
    vigiarWifi();
  }
  if (redeAtiva) {
    server.handleClient();
    MDNS.update();
    ArduinoOTA.handle();
  }
  atualizarEcra();
  delay(2);
}
