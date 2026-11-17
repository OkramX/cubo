#pragma once
// =====================================================================
//  Cubo de notificações — configuração
//  Edita só este ficheiro antes de compilar.
// =====================================================================

// ---- Segurança ------------------------------------------------------
// Código partilhado entre o cubo e o script do Mac. Usa algo comprido e
// aleatório (ex.: o resultado de `openssl rand -hex 16` no Terminal).
// Também é a palavra-passe das atualizações OTA e da página /update.
#define CUBO_TOKEN        "troca-isto-por-um-codigo-teu"

// Nome na rede: o cubo fica acessível em http://cubo.local
#define CUBO_HOSTNAME     "cubo"

// Nome da rede Wi-Fi que o cubo cria quando ainda não está configurado
#define CUBO_AP_NOME      "Cubo-Setup"

// ---- Hardware (GeekMagic SmallTV e clones: ESP8266 + ST7789 240x240) -
// SPI por hardware: SCK = GPIO14, MOSI = GPIO13 (fixos no ESP8266)
#define PIN_TFT_DC        0
#define PIN_TFT_RST       2
#define PIN_BACKLIGHT     5
// Na maioria destes cubos a retroiluminação acende com sinal baixo.
// Se o ecrã ficar apagado (ou ao contrário: brilho invertido), muda para 0.
#define BACKLIGHT_ACTIVE_LOW 1

// Estes ecrãs não têm pino CS e precisam de SPI_MODE3.
// Se o ecrã ficar preto ou com lixo, experimenta SPI_MODE2.
#define TFT_SPI_MODE      SPI_MODE3
#define TFT_SPI_HZ        20000000UL
// Se as cores aparecerem trocadas (fundo branco em vez de preto), muda para 0.
#define TFT_INVERT        1
// 0..3 — roda o ecrã se a imagem aparecer de lado ou de pernas para o ar
#define TFT_ROTATION      2

// ---- Comportamento --------------------------------------------------
// Fuso horário de Portugal continental (muda a hora sozinho)
#define TZ_INFO           "WET0WEST,M3.5.0/1,M10.5.0"

// Segundos que cada alerta fica no ecrã
#define ALERTA_SEGUNDOS   15
// Duração do piscar da luz no início de cada alerta (milissegundos)
#define PISCAR_MS         1800

// O contador de notificações volta a zero ao fim de X minutos sem novas
// (0 = só volta a zero com o comando --limpar do script)
#define NAO_LIDAS_RESET_MIN 60

// Olhos animados que alternam com as horas no relógio
#define OLHOS_ATIVOS        1      // 0 = só as horas
#define OLHOS_CADA_SEGUNDOS 20     // segundos de horas entre cada aparição dos olhos

// Brilho em percentagem e horário noturno (horas inteiras, 0-23)
#define BRILHO_DIA        100
#define BRILHO_NOITE      10
#define HORA_NOITE_INICIO 20
#define HORA_NOITE_FIM    8
