# MacDash

[English](README.md) · **Português**

App nativo para macOS (SwiftUI) de limpeza e manutenção: Cuidado inteligente (verificação Essencial em um clique, ou Completa, que inclui arquivos grandes, restos de apps e dados de desenvolvedor), o Assistente (um diagnóstico offline do Mac inteiro ou de uma pasta, e perguntas respondidas pelo Apple Intelligence no próprio Mac), Aplicativos (desinstalar, itens de início e atualizações), Proteção (permissões de apps, verificações de segurança, Wi‑Fi e extensões de navegador), Antivírus, Processos, Lente de espaço, Disco externo, Arquivos duplicados e Fotos semelhantes.

Nada é removido sem a sua aprovação: toda verificação termina numa tela de revisão.

## Instalar

Escolha um:

1. **Terminal, uma linha (recomendado).** Cole isto no Terminal:
   ```sh
   curl -fsSL https://witchmymac.com/install.sh | bash -s macdash
   ```
   Ele baixa a versão mais nova do GitHub, confere o SHA-256, instala o MacDash em Aplicativos e abre. Não aparece aviso do macOS, porque arquivos baixados pelo `curl` não ganham a marca de "baixado da internet". Rode a mesma linha de novo para atualizar. O script é aberto: [install.sh](https://witchmymac.com/install.sh).
2. **Baixe o DMG** em [Releases](https://github.com/matthfaria96/MacDash/releases) ou em [witchmymac.com](https://witchmymac.com), arraste o MacDash para Aplicativos e libere uma vez com:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/MacDash.app"
   ```
   Ele só tira daquele app a marca de "baixado da internet".
3. **Baixe o DMG** e libere pelos Ajustes do Sistema: abra o app, clique em OK no aviso e vá em Ajustes do Sistema › Privacidade e Segurança › Abrir Mesmo Assim.

Requer macOS 13 ou mais novo.

## Compilar e abrir

```bash
scripts/dev.sh run     # compila (Debug) e abre o app
scripts/dev.sh build   # só compila
scripts/dev.sh test    # roda os testes
```

O app fica em `build/derived/Build/Products/Debug/MacDash.app` (bundle ID `com.macdash.app`). O projeto Xcode `MacDash.xcodeproj` é gerado a partir do [`project.yml`](project.yml) com `xcodegen generate`. Como o código está organizado: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Permissões

Em **Ajustes › Permissões** (e no primeiro uso) o app mostra, verificado ao vivo com o macOS:

- **Acesso Total ao Disco** (obrigatório): para examinar Mail, Safari, contêineres de apps e a Lixeira, e para ler as permissões dos apps em Proteção.
- **Gerenciamento de Apps**: para remover e atualizar outros apps.
- **Automação do System Events**: para ligar e desligar itens de início.
- **Notificações**: para avisar quando uma verificação agendada termina.

As senhas do Wi‑Fi ficam nas chaves do sistema: o macOS pede o usuário e a senha da sua conta do Mac. Escolha "Sempre Permitir" e aquela rede não pergunta de novo.

## Créditos e licenças

MacDash é software livre, Copyright (C) 2026 Matheus Faria, sob a licença **GNU AGPL v3.0** ([`LICENSE`](LICENSE)). Você pode usar, estudar, modificar e redistribuir; quem distribuir uma versão modificada precisa publicar o código dela sob a mesma licença.

- O MacDash inclui componentes de código aberto sob as licenças deles (MIT, BSD, GPL e AGPL). Os avisos estão em [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) e no app, em Ajustes › Sobre › Licenças de código aberto.
- O antivírus foi escrito do zero. Ele não contém código, regras nem bases de dados de nenhum produto comercial; usa o padrão de teste EICAR e regras próprias.
- Nomes de outros produtos citados pertencem aos seus donos; o MacDash não tem ligação com eles.
