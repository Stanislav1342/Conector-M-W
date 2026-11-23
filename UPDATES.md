# Структура папки `Документы/Конектор` и обновления

Всё, что относится к **Conector-M-W**, хранится в одном каталоге `/Users/stanislavhvostov/Documents/Конектор`:

## Структура каталогов

### Отслеживаются в Git (исходники и скрипты)
- `mac/` — приложение для macOS на Swift, `Info.plist`, иконка `ConectorIcon.png` и логические тесты `mac/Tests/`.
- `windows/` — приёмник на Go для Windows, иконка `conector.ico` и тесты.
- `python/` — обёртка Python-пакета `prilo-receiver` (внутри `prilo_receiver/`).
- `homebridge/` — плагин Homebridge `homebridge-conector-m-w`.
- `scripts/` — скрипты проверки (`check.sh`), подписи (`sign-mac.sh`), установки (`update-mac.sh`), релиза (`release.sh`), сборки wheel (`build-python.sh`) и генерации иконок (`scripts/icon/`).
- `build.sh` — сборка всех артефактов в `dist/`.
- `README.md`, `UPDATES.md` — документация проекта.

### Локальные каталоги (исключены из Git через `.gitignore`)
- `app/Conector-M-W.app` — рабочая установленная копия приложения для запуска на этом Mac.
- `dist/` — готовые собранные файлы (`Conector-M-W.app`, `Conector-M-W-Mac.zip`, `ConectorMWReceiver.exe`, `ConectorMWReceiver-arm64.exe`, `homebridge-conector-m-w-*.tgz` и `dist/python/*.whl`).
- `.local/signing/` — локальный ключ и сертификат подписи Mac-приложения (`conector-signing.keychain-db`, пароль и `certificate.pem`). **Не удаляйте и не переносите в Git**: обновления, подписанные другим сертификатом, `Conector-M-W.app` отклонит.
- `.local/llvm-mingw/` — кросс-компилятор LLVM-MinGW для сборки `prilo_receiver.dll` под Windows (x64 и ARM64).

---

## Как запускать и обновлять на Mac

### Первый запуск
1. Открой `app/Conector-M-W.app` (двойным кликом в Finder или командой `open app/Conector-M-W.app`).
2. Разреши доступ к **локальной сети**, а в «Системных настройках → Конфиденциальность и безопасность» включи `Conector-M-W` в **Универсальном доступе** (и при необходимости в **Мониторинге ввода**).
3. Если ранее запускался оригинальный Prilo, сопряжение и подключение нужно выполнить один раз заново, так как у `Conector-M-W` свой сервис обнаружения (`_conector-mw._tcp`) и своё хранилище ключей.

### Локальное обновление после правок в коде (без GitHub)
Когда вносишь изменения в `mac/*.swift` и хочешь сразу проверить их на своём Mac:
```bash
cd ~/Documents/Конектор
./scripts/check.sh          # проверить код и тесты
./build.sh --mac-only       # пересобрать dist/Conector-M-W.app
# Закрой Conector-M-W (⌘Q), затем установи поверх:
./scripts/update-mac.sh     # обновит app/Conector-M-W.app с тем же сертификатом
open app/Conector-M-W.app
```
Так как подпись остаётся той же из `.local/signing/`, выданные разрешения macOS сохраняются.

### Автообновление на Mac через GitHub Releases (`Stanislav1342/Conector-M-W`)
1. Один раз настрой имя и почту для Git и отправь ветку `main` на GitHub:
   ```bash
   cd ~/Documents/Конектор
   git config user.name "Твоё Имя"
   git config user.email "твоя@почта"
   git add -A && git commit -m "feat: Conector-M-W"
   git push -u origin main
   ```
2. Для выпуска новой версии (например, `0.9.2`, должен быть выше текущего `0.9.0` в `mac/Info.plist`):
   ```bash
   cd ~/Documents/Конектор
   ./scripts/release.sh 0.9.2
   ```
   Скрипт сам поднимет версию в `mac/Info.plist`, прогонит `./scripts/check.sh`, соберёт через `./build.sh` и создаст релиз на `https://github.com/Stanislav1342/Conector-M-W/releases` с файлами `Conector-M-W-Mac.zip`, `ConectorMWReceiver.exe`, `ConectorMWReceiver-arm64.exe` и плагином Homebridge.
3. После публикации релиза в самом приложении на Mac открой **Настройки → Проверить обновления** (или пункт меню **«Проверить обновления…»**), затем нажми **«Установить и перезапустить»**.

---

## Как запускать и обновлять на Windows

### Вариант A: Python-приёмник через PyPI (`prilo-receiver`, запуск через `cmd`)
Python-приёмник обновляется не через GitHub Releases, а через PyPI.

1. **На Mac — сборка и публикация новой версии в PyPI** (например, `0.9.2`):
   ```bash
   cd ~/Documents/Конектор
   CONECTOR_PYTHON_VERSION=0.9.2 bash scripts/build-python.sh amd64 arm64
   python3 -m twine check dist/python/*.whl
   TWINE_USERNAME=__token__ TWINE_PASSWORD="pypi-..." python3 -m twine upload dist/python/prilo_receiver-0.9.2-*.whl
   ```
   *(Чтобы не вводить токен каждый раз в команде, его можно сохранить в `~/.pypirc` с правами `chmod 600`.)*

2. **На Windows — обновление и запуск в `cmd`**:
   - Если старый приёмник запущен, останови его через `Ctrl+C` в окне `cmd`.
   - Выполни обновление и запуск:
     ```cmd
     python -m pip install --upgrade --no-cache-dir --index-url https://pypi.org/simple prilo-receiver
     python -m prilo_receiver --manual
     ```
   - При первом подключении к `Conector-M-W` после перехода с Prilo введи в приложении на Mac данные из ручного режима (IP, новый код доступа и отпечаток) или выбери **«Найти ПК в сети»** при запуске `python -m prilo_receiver` без `--manual`. Далее профиль сохранится в `%APPDATA%\Conector-M-W\pairing.dat` и в Связке ключей macOS.

### Вариант B: Отдельный EXE-файл (`ConectorMWReceiver.exe`)
Если захочешь использовать автономный EXE со значком в трее и автообновлением из GitHub Releases:
1. Скопируй на Windows `dist/ConectorMWReceiver.exe` (x64) или `dist/ConectorMWReceiver-arm64.exe` (ARM64) — в папку вроде `%LOCALAPPDATA%\Conector-M-W`.
2. Обновления приёмник проверяет сам раз в сутки (или через меню в трее **«Проверить обновления…»**) после выхода нового релиза через `./scripts/release.sh` на GitHub.
3. Не запускай одновременно EXE и `python -m prilo_receiver`, так как оба слушают порт TCP `43821`.
