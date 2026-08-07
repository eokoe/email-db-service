#!/bin/bash
# End to end run against real containers: postgres + mailpit (a real SMTP server,
# with auth on) + nginx serving both the templates and the variables webhook.
#
#   ./xt/e2e-mailpit.sh          builds the image, sends a few e-mails, prints the raw message
#   ./xt/e2e-mailpit.sh clean    removes everything
#
# Open http://127.0.0.1:18025 to browse what was delivered.

set -euo pipefail
cd "$(dirname "$0")/.."

NET=emaildb-e2e
WWW=$(mktemp -d)

cleanup_containers() {
    docker rm -f e2e-pg e2e-mail e2e-www e2e-daemon >/dev/null 2>&1 || true
    docker network rm $NET >/dev/null 2>&1 || true
}

if [[ "${1:-}" == "clean" ]]; then
    cleanup_containers
    echo "removed"
    exit 0
fi

cleanup_containers
docker network create $NET >/dev/null

cat > "$WWW/vars.json" <<'EOF'
{"site_url":"https://app.example.com","support":"help@example.com","brand":"<b>ACME</b>"}
EOF

cat > "$WWW/welcome.html" <<'EOF'
<html><body>
<h1>Welcome [% name %] to [% cfg.brand | raw %]</h1>
<a href="[% cfg.site_url %]/u/[% user_id %]">open your account</a>
[% IF orders.size() > 0 %]
<ul>[% FOREACH o IN orders %]
  <li>[% o.title %] - [% o.total %][% IF o.late %] (late)[% END %]</li>[% END %]
</ul>
[% ELSE %]<p>no orders yet</p>[% END %]
<p>need help? [% cfg.support %]</p>
</body></html>
EOF
chmod -R a+rX "$WWW"

docker build -t emaildb:e2e .

docker run -d --name e2e-pg --network $NET -e POSTGRES_PASSWORD=pgpass -e POSTGRES_DB=emaildb postgres:16-alpine >/dev/null
docker run -d --name e2e-mail --network $NET -p 18025:8025 \
    -e MP_SMTP_AUTH='emaildb:s3cr3t-from-env' -e MP_SMTP_AUTH_ALLOW_INSECURE=1 axllent/mailpit >/dev/null
docker run -d --name e2e-www --network $NET -v "$WWW:/usr/share/nginx/html:ro" nginx:alpine >/dev/null

echo "waiting for postgres..."
for _ in $(seq 60); do docker exec e2e-pg psql -U postgres -d emaildb -c 'select 1' >/dev/null 2>&1 && break; sleep 1; done

docker exec -i e2e-pg psql -q -U postgres -d emaildb < deploy_db/deploy/0000-firstversion.sql
docker exec -i e2e-pg psql -q -U postgres -d emaildb < deploy_db/deploy/0001-config-variables-url.sql

# every secret and url of this config comes from the daemon environment
docker exec -i e2e-pg psql -q -U postgres -d emaildb <<'SQL'
INSERT INTO emaildb_config (id, "from", template_resolver_class, template_resolver_config,
                            email_transporter_class, email_transporter_config,
                            variables_url, variables_url_config)
VALUES (1,
  '"${MAIL_BRAND} Notifications" <no-reply@example.com>',
  'Shypper::TemplateResolvers::HTTP',
  '{"base_url":"${TEMPLATE_BASE_URL}","cache_timeout":5}',
  'Email::Sender::Transport::SMTP',
  '{"host":"e2e-mail","port":1025,"sasl_username":"emaildb","sasl_password":"${SMTP_PASS}"}',
  '${TEMPLATE_BASE_URL}vars.json',
  '{"namespace":"cfg"}');
SQL

docker run -d --name e2e-daemon --network $NET --init \
    -e EMAILDB_DB_HOST=e2e-pg -e EMAILDB_DB_USER=postgres -e EMAILDB_DB_PASS=pgpass -e EMAILDB_DB_NAME=emaildb \
    -e USE_STDOUT=1 -e VARIABLES_JSON_IS_UTF8=1 \
    -e TEMPLATE_BASE_URL=http://e2e-www/ \
    -e SMTP_PASS=s3cr3t-from-env \
    -e MAIL_BRAND=ACME \
    emaildb:e2e >/dev/null

sleep 5
docker logs e2e-daemon

docker exec -i e2e-pg psql -q -U postgres -d emaildb <<'SQL'
INSERT INTO emaildb_queue (config_id, template, "to", subject, variables)
VALUES (1, 'welcome.html', '"Renato" <renato@example.com>', 'txt + bcc + anexo: açúcar ☕',
 '{"name":"Renato","user_id":42,":txt":1,":bcc":"<chefe@example.com>","reply-to":"sac@example.com",
   "orders":[{"title":"Café ☕","total":"R$ 19,90","late":false},
             {"title":"Chá","total":"R$ 9,90","late":true}],
   "attachments_config":{"files":[{"name":"nota.txt","content_type":"text/plain",
                                   "disposition":"attachment","content":"bm90YSBmaXNjYWwK"}]}}');
SQL

sleep 5
echo
echo "=== delivered ==="
curl -s http://127.0.0.1:18025/api/v1/messages
echo
echo "=== raw of the first message ==="
ID=$(curl -s http://127.0.0.1:18025/api/v1/messages | sed -n 's/.*"ID":"\([^"]*\)".*/\1/p' | head -1)
curl -s "http://127.0.0.1:18025/api/v1/message/$ID/raw"
echo
echo "browse: http://127.0.0.1:18025   -   teardown: $0 clean"
