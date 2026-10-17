# MacDash

App nativo para macOS (SwiftUI) de limpeza e manutenção: Cuidado inteligente, Limpeza avançada, Aplicativos (desinstalar, itens de início e atualizações), Proteção (permissões de apps, verificações de segurança, Wi‑Fi e extensões de navegador), Processos, Lente de espaço, Arquivos duplicados e Fotos semelhantes.

Nada é removido sem a sua aprovação: toda verificação termina numa tela de revisão.

## Compilar e abrir

```bash
scripts/dev.sh run     # compila (Debug) e abre o app
scripts/dev.sh build   # só compila
scripts/dev.sh test    # roda os testes
```

O app fica em `build/derived/Build/Products/Debug/MacTidy.app`. O projeto Xcode é `PureMac.xcodeproj` (scheme `PureMac`). Os nomes internos do projeto continuam `PureMac`; o produto é `MacTidy.app`, com bundle ID `com.mactidy.app`. Requer macOS 13 ou mais novo.

## Permissões

Em **Ajustes › Permissões** (e no primeiro uso) o app mostra, verificado ao vivo com o macOS:

- **Acesso Total ao Disco** (obrigatório): para examinar Mail, Safari, contêineres de apps e a Lixeira, e para ler as permissões dos apps em Proteção.
- **Gerenciamento de Apps**: para remover e atualizar outros apps.
- **Automação do System Events**: para ligar e desligar itens de início.
- **Notificações**: para avisar quando uma verificação agendada termina.

As senhas do Wi‑Fi ficam nas chaves do sistema: o macOS pede o usuário e a senha da sua conta do Mac. Escolha "Sempre Permitir" e aquela rede não pergunta de novo.

## Créditos e licenças

- Base: [PureMac](https://github.com/momenbasel/PureMac), licença MIT ([`LICENSE`](LICENSE)).
- Recursos adaptados do [Mac Sai](https://github.com/iliyami/MacSai), licença BSD de 3 cláusulas ([`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)).
