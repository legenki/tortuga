# Публикация Tortuga в Firefox Add-ons и Chrome Web Store

Пошаговый гайд для первой публикации. Технические шаги релиза (теги, сборка
установщиков, Chrome-ключ) описаны в [RELEASE.md](../RELEASE.md); здесь —
магазины: аккаунты, загрузка, тексты листинга, ответы ревьюерам.

## Коротко: реально ли?

| | Firefox Add-ons (AMO) | Chrome Web Store |
|---|---|---|
| Шансы | **Высокие** | **Средние** |
| Стоимость | бесплатно | разовый взнос $5 |
| Ревью | ручное (nativeMessaging, proxy, `<all_urls>`, собранный код) — от дней до пары недель | обычно несколько дней, с широкими правами дольше |
| Главный риск | ревьюеру нужен помощник, чтобы проверить работу | правило **single purpose**: Tor и торренты — две функции в одном расширении |

Расширения с нативным помощником (менеджеры паролей, KeePassXC-Browser и т. п.)
и прокси-расширения в обоих магазинах — обычное дело. Ничего запрещённого в
Tortuga нет: Tor легален, торрент-клиент — инструмент, а не пиратство.

### Что уже исправлено под требования магазинов

- **Иконка** 16/32/48/96/128 (`extension/public/icons/`, исходники в
  `extension/icons/*.svg`, рендер — `extension/scripts/icons.mjs`). Иконка
  128 — черепаха 96×96 с полями по 16 px, как просит Chrome.
- **Название** `Tortuga` вместо `Tortuga — Tor routing`. [Политика товарных
  знаков Tor](https://www.torproject.org/about/trademark/) запрещает «Tor» в
  названии продукта и приводит в пример ровно такой шаблон
  (`BROWSER X – connect to the Tor network!`). В описаниях «Tor» можно
  использовать описательно — «routes through the Tor network» — и стоит
  добавить «not affiliated with the Tor Project».
- **Firefox для Android убран** (`gecko_android`): на Android нет native
  messaging, расширение там не работает. Минимальная версия Firefox — 142.
  `web-ext lint`: 0 ошибок, 0 предупреждений.
- **Политика конфиденциальности** — [PRIVACY.md](../PRIVACY.md). Ссылка на
  неё: `https://github.com/legenki/tortuga/blob/main/PRIVACY.md`.

### Главный риск в Chrome: single purpose

Политика Chrome: «An extension must have a single purpose that is narrow and
easy to understand», и «If two pieces of functionality are clearly separate,
they should be put into two different extensions». Tor-маршрутизация и
торренты ревьюер вполне может счесть двумя целями.

Варианты:

1. **Попробовать как есть** с формулировкой цели «private browsing and
   downloading through a local helper». Если отклонят — письмо придёт с
   причиной, исправить и отправить заново можно сразу.
2. **Сделать Chrome-сборку только с Tor** (вкладку Downloads, контент-скрипт и
   контекстное меню скрыть при `__TARGET__ === 'chrome'`), торренты оставить
   в Firefox. Надёжнее, но меньше функций в Chrome.

Рекомендация: начать с AMO, параллельно отправить в Chrome как есть (вариант
1), и переходить к варианту 2 только если откажут.

Ещё одна строка политики Chrome касается торрентов напрямую: «Do not encourage,
facilitate, or enable the unauthorized access, download, or streaming of
copyrighted content». Поэтому в листинге, на скриншотах и в примерах — только
легальные раздачи (Debian, Ubuntu, Blender, Internet Archive), без фильмов и
трекеров с пиратским контентом.

## Перед загрузкой: что подготовить

| Что | Где взять | AMO | Chrome |
|---|---|---|---|
| Пакет расширения | `tortuga-firefox-<v>.zip`, `tortuga-chrome-<v>.zip` из [релиза](https://github.com/legenki/tortuga/releases/latest) или `npm run package` / `package:firefox` | ✓ | ✓ |
| Исходники для ревьюеров | `tortuga-firefox-<v>-source.zip` | ✓ | – |
| Chrome-ключ | `~/tortuga-chrome-key.pem` (держать в бэкапе!) | – | ✓ |
| Иконка 128 | `extension/public/icons/icon-128.png` | ✓ | ✓ |
| Скриншоты 1280×800 (или 640×400) | ещё нет — см. ниже | желательно | ✓ минимум 1 |
| Small promo tile 440×280 | ещё нет | – | ✓ |
| Политика конфиденциальности | ссылка на PRIVACY.md | желательно | ✓ |
| Почта для поддержки | любая твоя | ✓ | ✓ |

Скриншоты: в `docs/screenshots/` есть снимки попапа 340 px шириной. Для
магазинов их нужно положить на холст 1280×800 (попап по центру, фон в цвет
темы, короткая подпись сверху), как сделано в Nomada (`store-assets/`).

## Firefox Add-ons (AMO)

### 1. Аккаунт

1. Зайди на <https://addons.mozilla.org/developers/> и войди Mozilla-аккаунтом.
2. Включи двухфакторную аутентификацию, если AMO попросит, — без неё он не
   даёт отправлять дополнения.
3. Прими Firefox Add-on Distribution Agreement при первой отправке.

### 2. Загрузка

1. **Submit a New Add-on** → **On this site** (listed: будет в каталоге и
   будет обновляться у пользователей автоматически).
2. Загрузи `tortuga-firefox-<v>.zip`. Автоматическая проверка покажет те же
   результаты, что `npm run lint:firefox` (сейчас чисто).
3. **Compatibility**: отметь только **Firefox**, сними **Firefox for
   Android**.
4. **Source code**: «Do you need to submit source code?» → **Yes**, потому что
   Vite собирает и минифицирует код. Загрузи
   `tortuga-firefox-<v>-source.zip`. Инструкция по сборке внутри:
   `extension/BUILD.md`.

### 3. Листинг

- **Name:** `Tortuga`
- **Add-on URL:** `tortuga` (если занято — `tortuga-tor`)
- **Summary** (до 250 символов):

  > Routes Firefox through the Tor network with a separate circuit for each
  > site, shows each site's route as a metro map, and downloads torrents from
  > links. Needs the free Tortuga helper app. Hides your IP; it is not Tor
  > Browser.

- **Description:**

  > Tortuga sends Firefox through the Tor network, without switching to another
  > browser.
  >
  > • One switch: Direct or Tor.
  > • A separate Tor circuit for each site, drawn as a metro line: you, the
  >   bridge or guard, the middle relay, the exit and the site, with country
  >   flags. "New circuit" gives a site a fresh path.
  > • Bridges for blocked networks: Snowflake out of the box; obfs4 and
  >   WebTunnel lines fetched from bridges.torproject.org in one click.
  > • No leaks: if Tor stops, pages are blocked instead of loading from your
  >   real IP.
  > • Torrent downloads: click a magnet or .torrent link, see the name and
  >   size, confirm. Torrents download directly from your own IP, not through
  >   Tor, and Tortuga says so every time.
  >
  > Tortuga needs the Tortuga helper, a small program that runs Tor (Arti, the
  > Tor Project's Rust implementation) on your computer. Installers for macOS,
  > Debian/Ubuntu and Windows: https://github.com/legenki/tortuga/releases
  >
  > While Tor is on, Tortuga turns on Firefox's resistFingerprinting and turns
  > off WebRTC for the whole browser, and puts both back when you switch to
  > Direct.
  >
  > Tortuga is not Tor Browser: your browser's fingerprint stays your own. If
  > your safety depends on anonymity, use Tor Browser. Tortuga is not made by
  > or affiliated with the Tor Project.

- **Categories:** Privacy & Security; второй — Download Management.
- **Support email / website:** почта и `https://github.com/legenki/tortuga/issues`
- **License:** All Rights Reserved (как в README). Если позже откроешь код
  под MIT/MPL — поменяешь здесь.
- **Privacy policy:** вставь текст PRIVACY.md (AMO принимает текст, не ссылку).

### 4. Notes to Reviewer

Ревьюеру нужен помощник, иначе он увидит только «helper not installed».
Вставь в поле **Notes to Reviewer**:

> The extension controls a native helper (native messaging host
> `org.tortuga.helper`) that runs Tor via Arti and downloads torrents via
> librqbit. The helper is open source in the same repository
> (https://github.com/legenki/tortuga, folder helper/), and installers
> are at https://github.com/legenki/tortuga/releases/tag/v<v> —
> `Tortuga-Helper-<v>-macos.pkg`, `tortuga-helper_<v>_amd64.deb`, or the
> Windows zip with `install.ps1` (per-user, no admin rights).
>
> To test: install the helper, open the popup, switch Direct → Tor. It
> connects in 5–30 s; open https://check.torproject.org/ and the Route tab
> shows that site's circuit. For downloads, click the magnet link for
> Debian netinst on https://www.debian.org/CD/torrent-cd/ and confirm.
>
> Build: see extension/BUILD.md in the source archive (`npm ci && npm run
> build:firefox`, output in dist-firefox/).
>
> Permissions: proxy (route traffic via the helper's SOCKS port), privacy
> (WebRTC off and resistFingerprinting while Tor is on, restored on Direct),
> nativeMessaging (helper), tabs (route for the active tab's site),
> contextMenus ("Download with Tortuga" on links), <all_urls> (proxy for all
> sites; content script catches clicks on magnet/.torrent links only). No
> remote code, no analytics, no data sent to the developer.

Если `.pkg` не подписан, macOS у ревьюера потребует «Open Anyway» — это
нормально, но подписанный установщик снимает лишний вопрос (секреты для
подписи — в RELEASE.md).

### 5. После отправки

- Статус — в Developer Hub, письма приходят на почту аккаунта.
- Вопросы ревьюера приходят там же; отвечай в том же треде.
- После одобрения ссылка будет вида
  `https://addons.mozilla.org/firefox/addon/tortuga/`. Добавь бейдж в README,
  как у Nomada.

## Chrome Web Store

### 1. Аккаунт

1. <https://chrome.google.com/webstore/devconsole> → войти Google-аккаунтом.
2. Оплатить регистрацию ($5, один раз), заполнить имя издателя и
   подтвердить почту. Google может попросить подтверждение личности — это
   занимает до пары дней.
3. Включить двухэтапную аутентификацию в Google-аккаунте (обязательна для
   публикации).

### 2. Пакет с ключом (только первый раз)

Чтобы ID в магазине совпал с закреплённым `mcdcmhcflckdnpnfgkfelnabooklecde`
(под него зарегистрированы установщики помощника):

```bash
cd extension
npm run package
cp tortuga-chrome-0.1.0.zip ~/tortuga-chrome-first-upload.zip
cp ~/tortuga-chrome-key.pem /tmp/key.pem
(cd /tmp && zip ~/tortuga-chrome-first-upload.zip key.pem && rm key.pem)
```

Загружай `~/tortuga-chrome-first-upload.zip`. После загрузки сверь ID на
странице товара с `python3 helper/packaging/hosts.py chrome-id`. Если не
совпал — см. RELEASE.md («copy the dashboard's public key»), пересобери
установщики. Все следующие версии грузятся обычным zip без ключа.

### 3. Store listing

- **Description** — тот же текст, что для AMO (с «Chrome» вместо «Firefox» и
  поправкой про Incognito):

  > In Chrome, Tortuga routes **Incognito windows** through Tor (regular
  > windows stay direct), on one shared circuit. Allow it under Manage
  > extension → Allow in Incognito.

- **Category:** Privacy & Security (или Tools).
- **Language:** English.
- **Icon:** `icon-128.png`. **Screenshots:** 1–5 штук 1280×800.
  **Small promo tile:** 440×280.
- **Official URL / Homepage:** `https://github.com/legenki/tortuga`.
- **Support URL:** `https://github.com/legenki/tortuga/issues`.

### 4. Privacy practices (самая важная вкладка)

**Single purpose description:**

> Tortuga lets you browse privately over the Tor network and download files
> from torrent links, using a local helper app that runs Tor and the torrent
> client on the user's computer.

**Permission justification** (по одному полю на право):

| Permission | Текст |
|---|---|
| `proxy` | Sends Incognito windows' traffic to the local Tor SOCKS port opened by the Tortuga helper. |
| `privacy` | While Tor is on, sets WebRTC IP handling to disable_non_proxied_udp so WebRTC can't reveal the user's real IP; restored when Tor is off. |
| `nativeMessaging` | Talks to the Tortuga helper app on the user's computer, which runs Tor and downloads torrents. |
| `storage` | Saves settings locally: Tor on/off, chosen bridge, bridge lines, the download list. |
| `contextMenus` | Adds "Download with Tortuga" to the context menu of links. |
| Host permission / content script `<all_urls>` | The content script only detects clicks on magnet and .torrent links on any page, to offer the download. It reads nothing else and sends nothing off the device. |
| Remote code | **No**, I am not using remote code. |

**Data usage:** не собираешь ничего — не отмечай ни одной категории. Отметь
три подтверждения (не продаёшь данные; не используешь для посторонних целей;
не используешь для кредитоспособности).

**Privacy policy URL:** `https://github.com/legenki/tortuga/blob/main/PRIVACY.md`

### 5. Distribution и отправка

- **Visibility:** Public; **Regions:** все.
- **Submit for review.** Если поле «notes for reviewer» есть в форме — вставь
  тот же текст, что для AMO. Особо подчеркни, что помощник открыт и лежит в
  GitHub Releases.
- Если отклонят по single purpose — см. вариант 2 выше.

## После публикации

1. Добавить бейджи магазинов в README (как в Nomada):
   - `https://img.shields.io/amo/v/tortuga?label=Firefox%20Add-ons`
   - `https://img.shields.io/chrome-web-store/v/mcdcmhcflckdnpnfgkfelnabooklecde?label=Chrome%20Web%20Store`
2. В README в разделе Install заменить «build it yourself» на ссылки магазинов.
3. Каждый новый релиз: тег → CI собирает zip → загрузить в оба магазина
   (RELEASE.md, шаг 4). Обновления AMO тоже проходят ревью, но обычно быстрее.
