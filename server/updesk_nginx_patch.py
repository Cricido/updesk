from pathlib import Path


PATH = Path("/etc/nginx/sites-enabled/updesk-static")
UPDATE_LOCATIONS = """

    location /api/ {
        root /var/www/updesk;
        default_type application/json;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        try_files $uri =404;
    }

    location /releases/ {
        root /var/www/updesk;
        add_header Cache-Control "public, max-age=300";
        try_files $uri =404;
    }
"""


def main():
    text = PATH.read_text(encoding="utf-8")
    text = text.replace(
        "location /ws/id {\n        proxy_pass http://127.0.0.1:21121;\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection \"upgrade\";\n        proxy_set_header Host $host;\n        proxy_read_timeout 120s;\n        proxy_send_timeout 120s;\n    }",
        "location /ws/id {\n        proxy_pass http://127.0.0.1:21121;\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection \"upgrade\";\n        proxy_set_header Host $host;\n        proxy_read_timeout 3600s;\n        proxy_send_timeout 3600s;\n        proxy_buffering off;\n    }",
    )
    text = text.replace(
        "location /ws/relay {\n        proxy_pass http://127.0.0.1:21119;\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection \"upgrade\";\n        proxy_set_header Host $host;\n        proxy_read_timeout 120s;\n        proxy_send_timeout 120s;\n    }",
        "location /ws/relay {\n        proxy_pass http://127.0.0.1:21129;\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection \"upgrade\";\n        proxy_set_header Host $host;\n        proxy_read_timeout 3600s;\n        proxy_send_timeout 3600s;\n        proxy_buffering off;\n    }",
    )
    text = text.replace(
        "location /ws/relay {\n        proxy_pass http://127.0.0.1:21119;\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection \"upgrade\";\n        proxy_set_header Host $host;\n        proxy_read_timeout 3600s;\n        proxy_send_timeout 3600s;\n        proxy_buffering off;\n    }",
        "location /ws/relay {\n        proxy_pass http://127.0.0.1:21129;\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection \"upgrade\";\n        proxy_set_header Host $host;\n        proxy_read_timeout 3600s;\n        proxy_send_timeout 3600s;\n        proxy_buffering off;\n    }",
    )
    if "location /api/" not in text:
        text = text.replace(
            "\n    location / {\n        return 404;\n    }\n",
            UPDATE_LOCATIONS + "\n    location / {\n        return 404;\n    }\n",
        )
    PATH.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
