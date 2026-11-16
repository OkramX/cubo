# Cubo de notificações

Transforma o "Smart Weather Clock" (GeekMagic SmallTV ou clone: ESP8266 + ecrã ST7789 240×240) num ecrã que mostra um relógio e avisa sempre que chega uma notificação ao Mac.

```
Mac  ──(lê o Centro de Notificações)──►  script Python  ──(Wi-Fi do escritório)──►  Cubo
```

O cubo mostra a app e o remetente, pisca a luz durante 2 segundos e volta ao relógio. Fica um contador de notificações recentes no fundo do ecrã.

## O que está nesta pasta

| Ficheiro | Para quê |
|---|---|
| `cubo-firmware-4MB.bin` | Firmware pronto a gravar (cubos com 4 MB de flash, o mais comum) |
| `cubo-firmware-1MB.bin` | O mesmo, para cubos com 1 MB de flash |
| `firmware/` | Código-fonte do firmware (PlatformIO), se quiseres alterar alguma coisa |
| `mac/` | Script do Mac e instalador |

## Passo 0 — Escolher o código secreto

O cubo só aceita notificações de quem souber um código partilhado. Gera um no Terminal do Mac:

```
openssl rand -hex 16
```

Guarda o resultado: vais pô-lo no cubo (passo 3) e no Mac (passo 4).

## Passo 1 — Cópia de segurança do firmware original

Antes de apagar o que lá está, guarda uma cópia. Instala o esptool (`pip3 install esptool`), liga o cubo por USB e corre:

```
esptool.py flash_id
esptool.py read_flash 0 ALL backup-original.bin
```

O `flash_id` mostra o tamanho da memória ("Detected flash size: 4MB" ou "1MB"). É isso que decide qual dos dois `.bin` vais usar.

Se o Mac não detetar nenhuma porta série com o cubo ligado, o cabo USB do cubo só dá energia. Passa para o passo 2-B.

## Passo 2 — Gravar o firmware novo

**A) Por USB (se o passo 1 funcionou)**

1. Abre https://web.esphome.io no Chrome ou Edge.
2. Connect → escolhe a porta do cubo → Install → escolhe o `.bin` certo.

Em alternativa, pelo Terminal:

```
esptool.py write_flash 0x0 cubo-firmware-4MB.bin
```

**B) Com adaptador USB-TTL de 3,3 V (se o USB não tiver dados)**

1. Abre a caixa com cuidado.
2. Liga o adaptador ao conector de 4 pinos da placa: pino 1 (pad quadrado) GND, 2 TX, 3 RX, 4 3V3. O TX do adaptador vai ao RX da placa e vice-versa.
3. Usa só 3,3 V. Com 5 V podes queimar o ESP8266.
4. Liga o GPIO0 ao GND enquanto dás energia, para entrar em modo de gravação.
5. Faz o backup (passo 1) e grava com o `esptool.py write_flash` acima.

## Passo 3 — Ligar o cubo ao Wi-Fi do escritório

1. O ecrã mostra "Configurar Wi-Fi". Liga o telemóvel à rede **Cubo-Setup**.
2. Abre http://192.168.4.1 → Configure WiFi.
3. Escolhe a rede do escritório, põe a palavra-passe e, no campo **Codigo secreto**, cola o código do passo 0.
4. Guarda. O cubo reinicia e mostra o IP e `cubo.local`.

Depois disto, as atualizações futuras fazem-se sem cabo, em http://cubo.local/update (utilizador `admin`, palavra-passe = o código secreto).

## Passo 4 — Instalar o script no Mac

```
cd mac
./instalar.sh
```

O instalador:

- copia o script para `~/Library/Application Support/Cubo/`;
- cria o `config.json`;
- deixa o serviço a arrancar sozinho com o Mac;
- abre as Definições no sítio certo.

Faltam três coisas:

1. **Põe o código secreto** no campo `token` de `~/Library/Application Support/Cubo/config.json`.
2. **Dá Acesso Total ao Disco ao Python.** O instalador mostra o caminho exato a adicionar. Sem isto, o macOS não deixa ler as notificações.
3. **Testa:**

```
python3 ~/Library/Application\ Support/Cubo/cubo_notificacoes.py --verificar
python3 ~/Library/Application\ Support/Cubo/cubo_notificacoes.py --teste
launchctl kickstart -k gui/$(id -u)/pt.cubo.notificacoes
```

O último comando reinicia o serviço depois de mudares a configuração.

## Configuração (`config.json`)

| Campo | O que faz |
|---|---|
| `cubo_url` | Endereço do cubo. Se `cubo.local` falhar, usa o IP (ex.: `http://192.168.1.57`). O ideal é fixar esse IP no router. |
| `token` | O código secreto. |
| `apps` | Apps que aparecem no cubo, com o nome a mostrar. Para descobrir os identificadores: `--listar-apps`. |
| `todas_as_apps` | `true` para mostrar todas as apps, exceto as de `apps_ignoradas`. |
| `mostrar_titulo` | Normalmente o remetente ou contacto. Ligado por omissão. |
| `mostrar_subtitulo` | No Mail, o assunto. Desligado por omissão. |
| `mostrar_texto` | O início da mensagem. Desligado por omissão. |
| `codigos_verificacao` | `esconder` (por omissão), `ignorar` ou `mostrar`, para notificações com códigos 2FA. |

Por omissão, o cubo só mostra a app e o remetente, porque o ecrã fica à vista de quem passa e os emails podem ter dados de clientes. O conteúdo das notificações nunca sai da rede local nem fica no registo.

## Outros comandos

```
--listar-apps   apps que enviaram notificações e quantas
--limpar        põe o contador do cubo a zero
```

Também podes mudar o brilho:

```
curl -X POST -H "X-Token: CODIGO" "http://cubo.local/brilho?valor=40"
```

Usa `valor=-1` para voltar ao brilho automático, que baixa à noite.

## Se alguma coisa não funcionar

| Sintoma | O que fazer |
|---|---|
| Ecrã preto, mas o cubo aparece na rede | Em `firmware/include/config.h`, muda `BACKLIGHT_ACTIVE_LOW` para 0, ou `TFT_SPI_MODE` para `SPI_MODE2`, e recompila. |
| Cores trocadas (fundo branco) | `TFT_INVERT` para 0. |
| Imagem de lado ou ao contrário | `TFT_ROTATION` entre 0 e 3. |
| `--verificar` diz "unable to open" ou "authorization denied" | Falta o Acesso Total ao Disco. Se funcionar no Terminal mas não no serviço, adiciona também o `Python.app` indicado pelo instalador. |
| "A estrutura da base de dados mudou" | Uma atualização do macOS mexeu na base de dados interna. O script tem de ser ajustado. |
| Cubo inacessível em `cubo.local` | Usa o IP no `cubo_url`. Algumas redes de escritório bloqueiam mDNS. Confirma também que o Mac e o cubo estão na mesma rede, porque redes de convidados costumam isolar dispositivos. |
| Mudar de rede Wi-Fi ou de código | `curl -X POST -H "X-Token: CODIGO" http://cubo.local/esquecer-wifi` e repete o passo 3. |
| Voltar ao firmware original | `esptool.py write_flash 0x0 backup-original.bin` |

## Recompilar o firmware (opcional)

Só precisas disto se quiseres mudar pinos, cores ou comportamento:

```
pip3 install platformio
cd firmware
pio run -t upload          # por USB
pio run -e cubo_1mb        # versão 1 MB
```

As definições estão todas em `firmware/include/config.h`.

## Nota sobre a leitura das notificações

A Apple não tem uma forma oficial de uma app ler as notificações das outras. O script lê a base de dados interna do Centro de Notificações, só em modo de leitura. Funciona no macOS 15 e seguintes (e nas versões anteriores, noutro caminho), mas é uma estrutura interna e pode mudar numa atualização. O script verifica a estrutura ao arrancar e avisa em vez de falhar sem dizer nada.
