# MacDash

[English](README.md) · **Português**

App nativo para macOS (SwiftUI) de limpeza e manutenção: Cuidado inteligente, Limpeza avançada, Aplicativos (desinstalar, itens de início e atualizações), Proteção (permissões de apps, verificações de segurança, Wi‑Fi e extensões de navegador), Processos, Lente de espaço, Arquivos duplicados e Fotos semelhantes.

Nada é removido sem a sua aprovação: toda verificação termina numa tela de revisão.

## Instalar

1. Baixe o `MacDash-x.y.z.dmg` em [Releases](https://github.com/matthfaria96/MacDash/releases) ou em [witchmymac.com](https://witchmymac.com).
2. Abra o DMG e arraste o **MacDash** para **Aplicativos**.
3. O app não é notarizado, então o macOS o bloqueia na primeira vez. Para liberar, cole isto no Terminal:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/MacDash.app"
   ```

   Isso só remove daquele app a marca de "baixado da internet".

   Sem o Terminal: abra o app, clique em **OK** no aviso e depois vá em **Ajustes do Sistema › Privacidade e Segurança** e clique em **Abrir Mesmo Assim**.

Requer macOS 13 ou mais novo.

## Compilar e abrir

```bash
scripts/dev.sh run     # compila (Debug) e abre o app
scripts/dev.sh build   # só compila
scripts/dev.sh test    # roda os testes
```

O app fica em `build/derived/Build/Products/Debug/MacDash.app`. O projeto Xcode é `PureMac.xcodeproj` (scheme `PureMac`). Os nomes internos do projeto continuam `PureMac`; o produto é `MacDash.app`, com bundle ID `com.macdash.app`. Requer macOS 13 ou mais novo.

## Permissões

Em **Ajustes › Permissões** (e no primeiro uso) o app mostra, verificado ao vivo com o macOS:

- **Acesso Total ao Disco** (obrigatório): para examinar Mail, Safari, contêineres de apps e a Lixeira, e para ler as permissões dos apps em Proteção.
- **Gerenciamento de Apps**: para remover e atualizar outros apps.
- **Automação do System Events**: para ligar e desligar itens de início.
- **Notificações**: para avisar quando uma verificação agendada termina.

As senhas do Wi‑Fi ficam nas chaves do sistema: o macOS pede o usuário e a senha da sua conta do Mac. Escolha "Sempre Permitir" e aquela rede não pergunta de novo.

## Créditos e licenças

MacDash é software livre, Copyright (C) 2026 Matheus Faria, sob a licença **GNU AGPL v3.0** ([`LICENSE`](LICENSE)). Você pode usar, estudar, modificar e redistribuir; quem distribuir uma versão modificada precisa publicar o código dela sob a mesma licença.

- Base: [PureMac](https://github.com/momenbasel/PureMac), licença MIT (aviso em [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)).
- Recursos adaptados do [Mac Sai](https://github.com/iliyami/MacSai), licença BSD de 3 cláusulas ([`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)).
- Anéis da Lente de Espaço adaptados do [SquirrelDisk](https://github.com/adileo/squirreldisk) (AGPL-3.0) e tamanho por app adaptado do [Disk Audit](https://github.com/srwiseman/diskaudit-macos) (GPL-3.0).
- Os demais créditos (Kitesail, Stats, Performance Monitor) estão em [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) e em Ajustes › Licenças de código aberto.
- O antivírus foi escrito do zero. Ele não contém código, regras nem bases de dados de nenhum produto comercial; usa o padrão de teste EICAR e regras próprias.
- Nomes de outros produtos citados pertencem aos seus donos; o MacDash não tem ligação com eles.
