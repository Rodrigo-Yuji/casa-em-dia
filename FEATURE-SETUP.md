# Recorrências variáveis e controles privados

Branch de implementação. Ainda não publicar no Pages antes da validação do banco.

Ordem planejada:

1. Reautorizar a integração Supabase para a organização que recebeu o projeto.
2. Conferir o schema atual e executar via migração os arquivos:
   - database/variable-recurrence.sql
   - database/private-pair-controls.sql
   - database/private-pair-reminders.sql
3. Executar tests/database.sql, tests/task-isolation.sql e tests/variable-and-private.sql com rollback.
4. Revisar os advisors e os grants/RLS das novas tabelas.
5. Atualizar a Edge Function casa-reminders com supabase/functions/casa-reminders/index.ts, preservando autenticação interna.
6. Validar a interface e os lembretes, atualizar a versão do service worker, então publicar no branch main.

Os controles privados usam tabelas separadas do controle da casa. Participantes são exatamente o criador e outro morador escolhido. A terceira pessoa não tem acesso nem à lista de controles, nem às tarefas, ausências ou histórico. Os rodízios e ausências também são separados. O outro participante precisa ser um morador já cadastrado na casa; o controle não cria contas nem envia convites por e-mail.

A recorrência “a cada X dias” usa a data inicial como âncora, aceita de 1 a 365 dias e não se desloca quando uma conclusão é registrada com atraso.

Pendência atual: a integração Supabase retorna “You do not have permission to perform this action” após a transferência do projeto. Os scripts SQL ainda não foram aplicados nem executados no servidor. Não considerar a validação local como prova de segurança do banco.
