#!/usr/bin/env python3
import os
import sys
import json
import socket
import logging
from jeepney.low_level import MessageType, HeaderFields
from jeepney.io.blocking import open_dbus_connection
from jeepney import new_error, new_method_return, DBusAddress, new_method_call

# 로그 및 데이터베이스 경로 설정
log_dir = "/data/data/com.termux/files/home/.gemini/antigravity-cli"
os.makedirs(log_dir, exist_ok=True)
log_file = os.path.join(log_dir, "log", "dummy-keyring.log")
db_file = os.path.join(log_dir, "dummy-keyring-db.json")

os.makedirs(os.path.dirname(log_file), exist_ok=True)

logging.basicConfig(
    filename=log_file,
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)

def load_db():
    if os.path.exists(db_file):
        try:
            with open(db_file, 'r') as f:
                return json.load(f)
        except Exception as e:
            logging.error(f"Failed to load DB: {e}")
    return {"items": {}}

def save_db(db):
    try:
        with open(db_file, 'w') as f:
            json.dump(db, f, indent=2)
    except Exception as e:
        logging.error(f"Failed to save DB: {e}")

def main():
    try:
        logging.info("Starting dummy keyring daemon (Persistent Active Secret Store mode)...")
        
        if 'DBUS_SESSION_BUS_ADDRESS' not in os.environ:
            logging.error("DBUS_SESSION_BUS_ADDRESS not found in environment.")
            sys.exit(1)
            
        connection = open_dbus_connection(bus='SESSION')
        logging.info("Connected and authenticated to D-Bus session bus.")
        
        bus = DBusAddress('/org/freedesktop/DBus',
                          bus_name='org.freedesktop.DBus',
                          interface='org.freedesktop.DBus')
                          
        # 다중 서비스 이름 선점 (Secrets API 및 KWallet 우회)
        for service_name in ['org.freedesktop.secrets', 'org.kde.kwalletd', 'org.kde.kwalletd5']:
            req_msg = new_method_call(bus, 'RequestName', 'su', (service_name, 4))
            reply = connection.send_and_get_reply(req_msg)
            logging.info(f"RequestName '{service_name}' result: {reply}")
        
        db = load_db()
        
        while True:
            try:
                # 상시 상주 모드로 무한 대기 (socket timeout 제거)
                msg = connection.receive()
            except Exception as e:
                logging.error(f"Error receiving message: {e}")
                break
                
            if msg.header.message_type == MessageType.method_call:
                member = msg.header.fields.get(HeaderFields.member, 'Unknown')
                interface = msg.header.fields.get(HeaderFields.interface, 'Unknown')
                path = msg.header.fields.get(HeaderFields.path, 'Unknown')
                logging.info(f"Received method call: {member} on interface: {interface} (path: {path})")
                
                # OpenSession
                if member == 'OpenSession' and interface == 'org.freedesktop.Secret.Service':
                    reply = new_method_return(
                        msg,
                        signature='vo',
                        body=(('s', ''), '/org/freedesktop/secrets/session/dummy')
                    )
                    connection.send(reply)
                    logging.info("Sent SUCCESS method return for OpenSession.")
                    continue
                
                # Get Property
                if member == 'Get' and interface == 'org.freedesktop.DBus.Properties':
                    prop_interface, prop_name = msg.body
                    logging.info(f"Get Property request: interface={prop_interface}, property={prop_name}")
                    if prop_name == 'Collections' and prop_interface == 'org.freedesktop.Secret.Service':
                        reply = new_method_return(
                            msg,
                            signature='v',
                            body=( ('ao', []), )
                        )
                        connection.send(reply)
                        logging.info("Sent SUCCESS method return for Collections property.")
                        continue
                
                # Unlock
                if member == 'Unlock' and interface == 'org.freedesktop.Secret.Service':
                    target_objects = msg.body[0] if msg.body else []
                    reply = new_method_return(
                        msg,
                        signature='aoo',
                        body=(target_objects, '/')
                    )
                    connection.send(reply)
                    logging.info(f"Sent SUCCESS method return for Unlock. Unlocked: {target_objects}")
                    continue
                
                # SearchItems (Go 클라이언트 맞춤형 1-arg 리턴)
                if member == 'SearchItems' and interface == 'org.freedesktop.Secret.Collection':
                    search_attrs = msg.body[0] if msg.body else {}
                    logging.info(f"SearchItems request attributes: {search_attrs}")
                    
                    found_paths = []
                    for item_path, item_data in db["items"].items():
                        attrs = item_data.get("attributes", {})
                        match = True
                        for k, v in search_attrs.items():
                            if attrs.get(k) != v:
                                match = False
                                break
                        if match:
                            found_paths.append(item_path)
                            
                    reply = new_method_return(
                        msg,
                        signature='ao',
                        body=(found_paths,)
                    )
                    connection.send(reply)
                    logging.info(f"Sent SUCCESS method return for SearchItems. Found: {found_paths}")
                    continue
                
                # CreateItem (아이템 저장)
                if member == 'CreateItem' and interface == 'org.freedesktop.Secret.Collection':
                    properties, secret_struct, replace = msg.body
                    logging.info(f"CreateItem properties keys: {list(properties.keys())}")
                    
                    attrs_var = properties.get('org.freedesktop.Secret.Item.Attributes', ('a{ss}', {}))
                    attrs = attrs_var[1] if isinstance(attrs_var, tuple) and len(attrs_var) > 1 else {}
                    
                    session_path, parameters, secret_val, content_type = secret_struct
                    secret_str = secret_val.decode('utf-8')
                    
                    # 중복 방지: 동일한 attributes를 가진 기존 항목이 있다면 찾아서 재사용
                    existing_path = None
                    for path_key, item_data in db["items"].items():
                        if item_data.get("attributes") == attrs:
                            existing_path = path_key
                            break
                            
                    if existing_path:
                        item_path = existing_path
                        logging.info(f"Overwriting existing secret at {item_path}")
                    else:
                        item_id = f"item_{len(db['items'])}"
                        item_path = f"/org/freedesktop/secrets/collection/default/{item_id}"
                        logging.info(f"Creating new secret at {item_path}")
                    
                    db["items"][item_path] = {
                        "attributes": attrs,
                        "secret": secret_str
                    }
                    save_db(db)
                    logging.info(f"Saved secret to {item_path} with attributes: {attrs}")
                    
                    reply = new_method_return(
                        msg,
                        signature='oo',
                        body=(item_path, '/')
                    )
                    connection.send(reply)
                    logging.info(f"Sent SUCCESS method return for CreateItem. Path: {item_path}")
                    continue
                
                # GetSecret (아이템 로드)
                if member == 'GetSecret' and interface == 'org.freedesktop.Secret.Item':
                    session_path = msg.body[0] if msg.body else '/'
                    item_path = path
                    
                    item_data = db["items"].get(item_path, {})
                    secret_str = item_data.get("secret", "")
                    secret_bytes = secret_str.encode('utf-8')
                    
                    secret_struct = (session_path, b'', secret_bytes, 'text/plain')
                    
                    reply = new_method_return(
                        msg,
                        signature='(oayays)',
                        body=(secret_struct,)
                    )
                    connection.send(reply)
                    logging.info(f"Sent SUCCESS method return for GetSecret of {item_path}")
                    continue
                
                # Close (세션 닫기)
                if member == 'Close' and interface == 'org.freedesktop.Secret.Session':
                    reply = new_method_return(msg, signature='', body=())
                    connection.send(reply)
                    logging.info("Sent SUCCESS method return for Session Close.")
                    continue
                
                # 그 외 모든 요청은 즉각 에러 반환
                error_reply = new_error(
                    msg,
                    "org.freedesktop.DBus.Error.NotSupported",
                    signature='s',
                    body=("Keyring operations are not supported in this dummy service.",)
                )
                connection.send(error_reply)
                logging.info("Sent ERROR response.")
                
    except Exception as e:
        logging.error(f"Error in dummy keyring daemon: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
