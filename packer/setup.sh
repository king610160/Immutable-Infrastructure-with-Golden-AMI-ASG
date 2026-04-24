#!/bin/bash
set -e  # 遇到錯誤立刻停止

# 移除原本的 exec > >(...) 邏輯，Packer 會幫你記日誌

echo "--- 階段 1: 更新系統與安裝編譯工具 ---"
sudo dnf update -y
sudo dnf groupinstall -y "Development Tools"
sudo dnf install -y pcre-devel zlib-devel openssl-devel libtool git cmake

echo "--- 階段 2: 下載 Nginx 與 Brotli ---"
cd /tmp
curl -L http://nginx.org/download/nginx-1.25.3.tar.gz -o nginx.tar.gz
tar -zxf nginx.tar.gz

git clone --recursive https://github.com/google/ngx_brotli.git
cd ngx_brotli/deps/brotli
mkdir -p out && cd out

cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_INSTALL_PREFIX=../installed ..
cmake --build . --config Release --target install
cd /tmp

echo "--- 階段 3: 執行配置與編譯 ---"
cd nginx-1.25.3
sudo ./configure \
    --prefix=/etc/nginx \
    --sbin-path=/usr/sbin/nginx \
    --add-module=/tmp/ngx_brotli \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-cc-opt="-I/tmp/ngx_brotli/deps/brotli/c/include" \
    --with-ld-opt="-L/tmp/ngx_brotli/deps/brotli/out"

sudo make && sudo make install

echo "--- 階段 4: 建立 Systemd 服務與設定檔 ---"
# 注意：在 Packer 裡面寫入系統路徑通常需要 sudo tee
sudo tee /etc/systemd/system/nginx.service <<EOF
[Unit]
Description=The HTTP and reverse proxy server
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
ExecStart=/usr/sbin/nginx
ExecReload=/usr/sbin/nginx -s reload
ExecStop=/usr/sbin/nginx -s stop

[Install]
WantedBy=multi-user.target
EOF

# 建立 HTML 目錄與檔案
sudo mkdir -p /etc/nginx/html
echo "<html><body><h1>Nginx is Ready (Golden AMI Mode)</h1></body></html>" | sudo tee /etc/nginx/html/index.html
echo "OK" | sudo tee /etc/nginx/html/health

# 簡化設定檔寫法
sudo tee /etc/nginx/conf/nginx.conf <<EOF
worker_processes  1;
events {
    worker_connections  1024;
}
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       80;
        server_name  localhost;

        location / {
            root   /etc/nginx/html;
            index  index.html;
        }

        location /health {
            access_log off;
            root /etc/nginx/html;
            try_files /health =200;
        }
    }
}
EOF

# 關鍵：只 enable 不用 start，因為 Packer 結束會關機
sudo systemctl daemon-reload
sudo systemctl enable nginx

# ## 最後的清理步驟，確保 AMI 不會太大
# # 移除編譯工具
# sudo dnf groupremove -y "Development Tools"
# sudo dnf remove -y cmake git libtool pcre-devel zlib-devel openssl-devel

# # 清理下載的原始碼與快取
# sudo rm -rf /tmp/*
# sudo dnf clean all

echo "--- Packer Build Step Completed ---"
# packer 安裝完後會關機