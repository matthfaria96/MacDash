# Arquitetura do MacDash

Mapa do repositório: o que cada pasta e cada arquivo faz, e as regras que o código segue.
Leia isto antes de mexer em algo que você não conhece. Regras de comportamento mais
detalhadas (Assistente, modo demo) estão no [`CLAUDE.md`](../CLAUDE.md).

## Visão geral

- App SwiftUI para macOS 13+, um único módulo Swift chamado `MacDash`.
- Produto `MacDash.app`, bundle ID `com.macdash.app`, esquema de URL `macdash://`.
- O projeto Xcode (`MacDash.xcodeproj`) é **gerado** a partir do [`project.yml`](../project.yml)
  com `xcodegen generate`. Nunca edite o `.xcodeproj` à mão: depois de criar, mover ou
  renomear arquivos, rode `xcodegen generate`.
- Dependência externa: só o [Sparkle](https://sparkle-project.org) (atualizações do próprio app).
- `scripts/dev.sh build|run|test` compila, abre ou testa (saída em `build/`, que não vai pro git).

## Raiz do repositório

| Caminho | O que é |
|---|---|
| `MacDash/` | Código e recursos do app |
| `MacDashFinder/` | Extensão do Finder (item "Analisar com o MacDash" no clique direito) |
| `MacDashTests/` | Testes unitários (XCTest), rodando dentro do app como host |
| `project.yml` | Fonte do projeto Xcode (alvos, versões, assinatura) |
| `scripts/dev.sh` | Compilar, abrir e testar no dia a dia |
| `docs/` | Esta documentação |
| `CLAUDE.md` | Regras e atalhos para quem desenvolve (inclusive o assistente de código) |
| `THIRD_PARTY_NOTICES.md` | Avisos de licença dos componentes de código aberto (obrigatórios) |
| `LICENSE` | GNU AGPL v3.0 |

## Dentro de `MacDash/`

O código está organizado **por funcionalidade**: cada tela da barra lateral tem a sua pasta
em `Features/`, com a lógica e a interface juntas. O que várias telas usam fica em `Shared/`.

```
MacDash/
├── App/          entrada do app, estado global, janela, migração
├── Features/     uma pasta por tela
├── Shared/       permissões, leitura do sistema, design
└── Resources/    ícones, traduções, Info.plist, entitlements
```

### `App/` — a casca do app

| Arquivo | Papel |
|---|---|
| `MacDashApp.swift` | `@main`, `AppDelegate` (barra de menus, Finder Services, evento de saída) e a cena da janela |
| `AppState.swift` | Estado compartilhado (`AppSection`, varredura/limpeza, desinstalação). É o maior arquivo: antes de pôr algo aqui, veja se não cabe num `Store` da própria funcionalidade |
| `MainWindow.swift` | Barra lateral, barra de ferramentas e a troca de telas por `AppSection` |
| `AppLanguage.swift` | Idioma escolhido nos Ajustes |
| `AppUpdater.swift` | Atualizações do próprio MacDash (Sparkle) |
| `AppVersion.swift` | Versão e build mostrados nos Ajustes |
| `DemoMode.swift` | `MACDASH_DEMO=1`: dados fictícios para as capturas do site |
| `LegacyMigration.swift` | **Único** lugar que conhece os nomes antigos do app (MacFresh, Mac Tidy). Importa ajustes antigos e renomeia chaves |

### `Features/` — uma pasta por tela

| Pasta | Tela | Arquivos principais |
|---|---|---|
| `SmartCare/` | Cuidado inteligente (tela inicial, a única tela de limpeza) | `SmartCareView` (início, profundidade, varredura e limpeza; do Mac, só a linha do disco), `ScanAreasSheet` ("Escolher áreas…" da Completa), `SmartCareResults` (resultados em dois blocos e revisão). Duas profundidades (`ScanDepth`): **Essencial** (lixo do sistema, caches, Lixeira, Mail; pré-selecionado) e **Completa** (soma as áreas escolhidas: arquivos grandes, restos de apps, apps sem uso, desenvolvedor e, se ligadas, máquinas virtuais). Sempre abre no Essencial (a escolha não é lembrada); as áreas da Completa ficam em `cleanup.disabledAreas` |
| `Assistant/` | Assistente (botão na barra de ferramentas) | `AssistantScanner` mede → `AssistantRules` interpreta → `AssistantStore` guarda relatórios → `AssistantExecutor` confere e manda pra Lixeira. `AssistantCatalog` é o que ele sabe. Na análise do Mac inteiro também lê a saúde dos discos e o backup (mesmas regras do cartão Saúde, `DeviceHealthRules`) e aponta para Processos; `AssistantDemo`, dados fictícios. Conversa: `AssistantChat` (modelo da Apple no próprio Mac; o app junta os fatos, o modelo só redige), que abre numa janela própria (`AssistantChatSheet`, a partir do cartão `AssistantChatLauncher`) e esquece tudo ao fechar |
| `Cleanup/` | Motor de limpeza (sem tela própria; usado pelo Cuidado inteligente) | `ScanEngine` (encontra), `CleaningEngine` (remove), `CleanupModels` (`CleaningCategory`, `CleanableItem`, `CleanupBundle`, `ScanDepth`…), `CleanupGrouping`/`CleanupReview` (agrupar e filtrar na revisão). Regras de segurança: `FileProtection`, `ProviderPaths`, `OrphanSafetyPolicy`, `CleanupExclusions`. Casos especiais: Xcode/simuladores, máquinas virtuais, idiomas e binários universais |
| `Applications/` | Aplicativos (3 abas) | `ApplicationsHubView` + uma subpasta por aba: `Uninstaller/` (lista de apps, arquivos que cada app deixa, apps sem uso), `Startup/` (itens de início), `Updates/` (Homebrew e Sparkle de outros apps) |
| `Protection/` | Proteção (4 abas) | `ProtectionHubView`; segurança do macOS (`ProtectionAudit`), permissões dos apps, extensões de navegador, redes Wi‑Fi salvas. Cada aba tem um leitor e uma `View` |
| `Antivirus/` | Antivírus | `AntivirusScanner` (só lê), `AntivirusRules` + `ThreatSignatures` (regras), `AntivirusStore` (pendentes, quarentena, confiáveis), `AntivirusView` |
| `SpaceLens/` | Lente de espaço | `SpaceLensScanner` + `DirectoryLister` (leitura rápida do disco), `AppFootprintScanner` (tamanho por app), três visões: mapa, anéis e apps |
| `DriveOffload/` | Disco externo | `DriveOffloadCatalog` (o que pode ir), `DriveOffloadEngine` (move e deixa link, com manifesto), `DriveOffloadStore`, `DriveOffloadView` |
| `Duplicates/` | Arquivos duplicados | `DuplicateFinder` + `DuplicateFinderView` |
| `SimilarPhotos/` | Fotos semelhantes | `SimilarPhotoFinder` + `SimilarPhotosView` |
| `Processes/` | Processos (a tela do Mac) | `ProcessesView`; no topo, o cartão "Seu Mac" (`MacProfileCard`: identidade, disco, ficha técnica); desempenho (`PerformanceOverview`, `MemoryInsights`; a página não observa o modelo: cada cartão observa só o que mostra, e a lista de apps segue `ProcessReadings`), apps abertos (`ProcessResourceMonitor`/`View`) e o cartão Saúde (`HealthOverview`, `DeviceHealthReader`, `DeviceHealthRules`) |
| `MenuBar/` | Item da barra de menus | `MenuBarController` (o `NSStatusItem`), `MenuBarModel`, `MenuBarReadout` (o número ao lado do ícone), painel e detalhes |
| `History/` | Histórico | `HistoryView` (relatórios do Assistente e números de uso), `UsageStats` |
| `Settings/` | Ajustes | `SettingsView` (inclusive Sobre), `OpenSourceLicensesView`, `SchedulerService` (limpeza agendada) |
| `Onboarding/` | Primeira abertura | `OnboardingView`, `PermissionsChecklist` |

### `Shared/` — o que várias telas usam

| Pasta | Conteúdo |
|---|---|
| `Permissions/` | Acesso Total ao Disco (`FullDiskAccessManager`, `PermissionCoordinator`, `PermissionSheet`, `AppBundleDragHandle`) e a lista de permissões do app (`MacDashPermissions`) |
| `System/` | Leitura do sistema sem pedir permissão: `SystemMonitor`, `HardwareSensors`, `MacStatusReaders` (bateria, rede, Bluetooth, discos), `MacSystemInfo` (nome, modelo, chip, macOS), `MacHardwareExtras` (clock, telas, pacotes, temperatura); utilitários `Shell`, `FileSize`, `Logger`, `Haptics` |
| `Design/` | Visual: `AppTheme` (cores por seção em `SectionPalette`, gradientes, movimento), `PremiumIcon` (ícones próprios), `DashboardCharts` (rosca, contadores), `EmptyStateView`, `ScanLocationPicker` |

### `Resources/`

`Assets.xcassets` (ícone do app, cor de destaque, imagens), `*.lproj/Localizable.strings`
(13 idiomas; a chave é o texto em inglês), `Info.plist` e `MacDash.entitlements`.

## Como ler um nome de arquivo

| Sufixo | Faz | Pode mudar o Mac? |
|---|---|---|
| `…Scanner`, `…Reader`, `…Finder`, `…Lister` | Mede e lista | Não |
| `…Rules`, `…Catalog`, `…Policy` | Regras fixas e testáveis: o mesmo Mac sempre recebe a mesma resposta | Não |
| `…Engine`, `…Executor`, `…Installer`, `…Control` | Executa o que a pessoa confirmou | Sim |
| `…Store`, `…Model`, `…Service` | Estado observável (`ObservableObject`) que liga lógica e tela | Por meio de um Engine |
| `…View`, `…Overview`, `…Card` | Interface SwiftUI | Não |

## Regras que valem para o app todo

1. **Nada sai sem revisão.** Toda varredura termina numa tela de revisão. A única exceção é a
   limpeza agendada com "limpar automaticamente" ligado pela pessoa, e mesmo ela só varre e limpa
   o Essencial, nunca o que só a Completa encontra (`AppState.scheduledCleanItemIDs`).
2. **Lixeira, não exclusão.** O que é removido vai para a Lixeira sempre que possível. Nunca
   adicione um "apagar direto" ou uma alternativa com senha de administrador no Assistente.
3. **Conferir de novo antes de agir.** Quem executa olha o arquivo outra vez (mesmo inode,
   ainda dentro da regra, app dono fechado) em vez de confiar na varredura.
4. **Nenhum aviso de permissão inesperado.** Sem Acesso Total ao Disco, nenhuma leitura abre
   pastas protegidas: o macOS não pode mostrar um pedido de permissão por causa de uma análise.
5. **Trabalho só quando a tela está aberta.** Amostragens (Processos, Saúde) param quando a tela
   fecha ou o app vai para segundo plano. Nada roda na abertura além do necessário.
6. **Offline.** Fora as atualizações (Sparkle, Homebrew), nada sai do Mac. A conversa do Assistente
   usa o modelo da Apple no próprio Mac, nunca um serviço na nuvem.
7. **IA explica, regras decidem.** O diagnóstico vem de regras fixas. O modelo só redige o que o app
   mediu e nunca tem como agir.

## Onde o app guarda dados

| O quê | Onde |
|---|---|
| Ajustes | `UserDefaults` de `com.macdash.app`. Chaves novas: `MacDash.<Nome>` ou `settings.<área>.<nome>` |
| Relatórios do Assistente | `~/Library/Application Support/MacDash/Assistant/` (registros, nunca executam nada) |
| Quarentena e estado do Antivírus | `~/Library/Application Support/MacDash/Antivirus/` |
| Pastas movidas para o disco externo | `~/Library/Application Support/MacDash/DriveOffload.json` (+ cópia no disco) |

Nunca renomeie uma chave de ajuste já publicada sem adicioná-la em
`LegacyMigration.renamedKeys`: quem já usa o app perderia o ajuste.

## Como adicionar uma tela nova

1. Crie `MacDash/Features/<Nome>/` com o leitor, as regras, o store e a view.
2. Adicione o caso em `AppSection` (`App/AppState.swift`), o título e o ícone em `SidebarItem`
   e a view no `switch` de `MainWindow.swift`.
3. Escolha a paleta em `SectionPalette` (`Shared/Design/AppTheme.swift`).
4. Textos novos: chave em inglês nos 13 `Localizable.strings`. O teste
   `LocalizationFilesTests` confere se todos têm as mesmas chaves e os mesmos `%@`/`%lld`.
5. Rode `xcodegen generate`, depois `scripts/dev.sh test`.

## Testes

`MacDashTests/` tem um arquivo por área (`AssistantTests`, `CleaningEngineTests`,
`ToolsTests` para Proteção, Wi‑Fi, extensões e atualizações etc.). Eles rodam dentro do app
(`TEST_HOST`) e usam pastas temporárias e domínios de `UserDefaults` próprios. Nunca varrem a
pasta pessoal de verdade.

## Licenças de terceiros

Partes do código vieram de projetos de código aberto (MIT, BSD, GPL, AGPL). As licenças exigem
que o aviso de copyright continue junto do código: por isso alguns arquivos começam com duas ou
três linhas de crédito, e `THIRD_PARTY_NOTICES.md` e a tela **Ajustes › Sobre › Licenças de
código aberto** listam tudo. Não remova esses avisos. Fora deles, o código, os nomes e a marca
são só do MacDash.
