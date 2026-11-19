# Plano: unificar Cuidado inteligente e Limpeza avançada

Status: **implementado** em 19/11/2026, com as decisões abaixo. A Limpeza avançada saiu da barra
lateral; quem tinha ela como última tela (`MacDash.lastSection = "cleanup"`) abre o Cuidado
inteligente, e os links que apontavam para ela abrem o Cuidado inteligente já na Completa.

Decisões tomadas: o nome continua "Cuidado inteligente"; o padrão é Essencial para todos e o app
sempre abre no Essencial (decidido depois: a escolha não é lembrada entre aberturas); as máquinas virtuais ficam na Completa, desligadas.

## Objetivo

Uma única tela de limpeza, a inicial, na paleta rosa-roxa do Cuidado inteligente. Ela vira o
chamariz do app: o básico em um clique e o avançado ao alcance, sem uma segunda tela que repete
o mesmo trabalho. A Limpeza avançada sai da barra lateral. O verde dela já foi para o Antivírus,
e o estilo do Antivírus foi para o Assistente.

## Como está hoje

| | Cuidado inteligente | Limpeza avançada |
|---|---|---|
| Varre | Lixo do sistema, caches de apps, Lixeira, anexos do Mail (`CleaningCategory.smartCare`) | 3 grupos (`CleanupBundle`): **Arquivos** (grandes e antigos, restos de apps removidos, apps sem uso), **Desenvolvedor** (Xcode, Homebrew, Node, Docker, apps de IA), **Máquinas virtuais** (arriscado, começa desligado) |
| Escolha | Nenhuma: tudo de uma vez | Cada área pode ser ligada e desligada (`disabledCleanupAreas`) |
| Estado | `ScanScope.smartCare` | `ScanScope.generalCleanup` |
| Revisão e limpeza | Já compartilhadas: `CleanupReviewScreen`, `CleanupActionBar`, `cleanAll` | (as mesmas) |
| Agendamento | A limpeza automática só toca itens daqui | Nunca é limpa automaticamente |

A revisão e a remoção já são as mesmas nas duas telas. O que as separa é a escolha das
categorias, o `ScanScope` e o visual. Isso torna a fusão mais simples do que parece.

## A proposta

### Uma varredura, dois níveis de profundidade

- **Essencial** (padrão): o que o Cuidado inteligente varre hoje. É rápido, seguro e vem
  pré-selecionado.
- **Completa**: o Essencial mais os grupos Arquivos e Desenvolvedor. Máquinas virtuais continuam
  opcionais, desligadas por padrão, como hoje.

O seletor fica logo abaixo do botão principal, como um segmento discreto
("Essencial · cerca de 1 min" / "Completa · inclui arquivos grandes e de desenvolvedor"), com um
link "Escolher áreas…" que abre os interruptores de hoje numa folha. A escolha fica salva.

**Por que não sempre completa:** a Completa demora mais (arquivos grandes, restos de apps) e mostra
itens que pedem decisão. Deixar o Essencial como padrão mantém o "um clique e pronto" que faz da
tela inicial um chamariz.

### Resultados em dois blocos

1. **Seguro para limpar**: as áreas do Essencial, pré-selecionadas, com o total grande no topo.
2. **Para revisar**: o que vem da Completa (arquivos grandes, restos, apps sem uso, desenvolvedor,
   máquinas virtuais). Nada vem pré-selecionado, exceto o que já é pré-selecionado hoje dentro de
   cada categoria. Cada cartão abre a mesma revisão de hoje.

O botão flutuante "Limpar X GB" soma só o que está marcado, como já faz.

### Alto padrão: a tela inicial

- **Herói**: a arte do Mac (`SmartCareCore`) com o halo magenta e uma frase que muda com o estado.
  Antes: "Seu Mac tem X GB livres". Depois: "X GB podem sair com segurança". O número é grande, em
  SF Rounded, com contagem animada (`CountUpBytes`).
- **Menos molduras**: um único painel de vidro para o "Seu Mac" (`MacHealthPanel`), e o resto
  direto sobre o fundo. Hoje há cartões dentro de cartões.
- **Durante a varredura**: os blocos das áreas acendem em sequência (`ScanAreaTile`), a linha do
  caminho atual fica discreta e a profundidade escolhida aparece no topo.
- **Movimento contido**: entrada escalonada (`StaggeredReveal`) só na primeira exibição dos
  resultados, nada em loop além do botão principal, e tudo respeitando "Reduzir movimento".
- **Tipografia**: título 28 pt arredondado com tracking negativo (como o Assistente), rótulos em
  versalete 11 pt, números monoespaçados.
- Validar com capturas no modo demo (`MACDASH_DEMO_RESULTS=smartCare`, janela 1080×780) antes e
  depois.

## Etapas

Cada etapa compila, passa nos testes e pode ir para o git sozinha.

1. **Estado (sem mudar a interface)**
   - `AppState`: `startSmartScan(depth:)` varre `CleaningCategory.smartCare` mais, na Completa,
     `enabledCleanupCategories`, os restos (`findOrphans`) e os apps sem uso.
   - `ScanScope` perde `.generalCleanup`. `smartCareResults` passa a cobrir tudo o que veio da
     varredura, com `isEssential` para separar os dois blocos.
   - Agendamento: continua só Essencial, e a limpeza automática continua só nos itens do Essencial.
     Isso ganha um teste.
   - Testes: profundidade → categorias; cancelar mantém o parcial; agendada nunca limpa a Completa.
2. **Tela**
   - `SmartCareView`: o seletor de profundidade, o herói novo e os resultados em dois blocos.
   - A folha "Escolher áreas…" reaproveita `BundleColumn` de `CleanupHubView`.
   - `CleanupHubView` e `GeneralCleanupRunView` são removidos no fim. O que servir vai para
     `Features/SmartCare/`.
3. **Navegação e links**
   - Sai da barra lateral: `.cleanup` em `MainWindow`.
   - `AppSection.cleanup` continua existindo só para abrir o Cuidado inteligente na Completa. Quem
     aponta para lá: `MacDash.lastSection` salvo, `AssistantTool.cleanup` (3 regras em
     `AssistantRules`), o botão "Limpar" do Disco externo e o `-DebugSection cleanup`.
   - Modo demo: `MACDASH_DEMO_RESULTS=cleanup` passa a abrir a Completa.
   - Onboarding: o cartão "Limpeza avançada" vira parte do Cuidado inteligente, e a cena final
     deixa de usar a paleta verde.
   - Histórico: `UsageStats` registra as duas profundidades como "Limpeza" (já é assim).
4. **Paleta e textos**
   - Remover `SectionPalette.cleanup`. Os grupos mantêm as cores de categoria (`cardTint`).
   - Textos novos nos 13 idiomas (o teste de localização confere).
   - Atualizar `docs/ARCHITECTURE.md`, `CLAUDE.md` e os READMEs (a lista de telas).

## Decisões (fechadas)

- **Nome**: manter "Cuidado inteligente" (recomendado, porque é a marca da tela inicial) ou algo
  como "Limpeza".
- **Profundidade padrão para quem já usava a Limpeza avançada**: começar na Completa para quem
  tinha resultados salvos dela? A recomendação é começar no Essencial para todos e lembrar a última
  escolha.
- **Máquinas virtuais**: ficam dentro da Completa (desligadas) ou vão para a Lente de espaço?
  A recomendação é ficarem na Completa, desligadas, como hoje.

## Riscos

- `AppState` é grande, e a mudança de escopo mexe em varredura, cancelamento e limpeza ao mesmo
  tempo. Por isso a etapa 1 vem sozinha e com testes.
- Ajustes salvos (`cleanup.disabledAreas`) devem continuar valendo, sem renomear as chaves.
- A Completa pode tocar pastas protegidas. As regras atuais continuam valendo: sem Acesso Total
  ao Disco, nada de pedido de permissão inesperado.
