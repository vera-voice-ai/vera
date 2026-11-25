# Чужие компоненты

Код Веры — под лицензией MIT ([LICENSE](LICENSE)). Вера собирает внутрь `Vera03.app` и iPhone-приложения чужие
компоненты. В репозитории лежат только заголовки C API. Всё остальное скрипты скачивают при сборке по замкам
([hermes.lock.json](hermes.lock.json), [ears.lock.json](ears.lock.json)) и сверяют по sha256. У каждого компонента своя
лицензия. Перед любым использованием, кроме личного, проверь её у источника.

| Компонент | Что делает в Вере | Где в репозитории | Лицензия |
|---|---|---|---|
| [Hermes Agent](https://github.com/NousResearch/hermes-agent) | мозг: агент, шлюз, инструменты | не лежит, `scripts/build-hermes.sh` | MIT |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | распознавание речи на Маке и iPhone | заголовок `app/Sources/CSherpa/vendor`, `phone/VeraPhoneDeps/CSherpaPhone` | Apache-2.0 |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | запуск сетей голоса на iPhone | заголовки `app/Sources/COnnx/vendor` | MIT |
| GigaAM v3, T-one, Silero VAD, CAM++ (сборки моделей sherpa-onnx) | уши: речь, конец фразы, голос говорящего | не лежат, `scripts/build-ears.sh` | у каждой модели своя, см. источник |
| [Smart Turn v3](https://huggingface.co/pipecat-ai/smart-turn-v3) | «фраза закончена?» | не лежит, `scripts/build-ears.sh` | см. источник |
| [Silero TTS](https://github.com/snakers4/silero-models) (голос baya) | голос Веры | не лежит, `scripts/build-mouth.sh`, `scripts/build-mouth-ios.sh` | своя лицензия Silero с ограничениями на коммерческое использование, см. источник |
| [Google Navigation SDK для iOS](https://github.com/googlemaps/ios-navigation-sdk) | навигатор на iPhone | Swift-пакет, версия в `scripts/phone-project.py` | условия Google Maps Platform, нужен свой ключ |

Ключи моделей, токен бота и ключ Google Maps в репозитории не хранятся: их вводит владелец в самом приложении.
