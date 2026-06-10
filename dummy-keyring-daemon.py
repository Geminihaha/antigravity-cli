#!/usr/bin/env python3
import os
import sys
import socket
import logging
from jeepney.low_level import MessageType, HeaderFields
from jeepney.io.blocking import open_dbus_connection
from jeepney import new_error, new_method_return, DBusAddress, new_method_call

# 로그 설정
log_dir = "/data/data/com.termux/files/home/.gemini/antigravity-cli/log"
os.makedirs(log_dir, exist_ok=True)
log_file = os.path.join(log_dir, "dummy-keyring.log")

logging.basicConfig(
    filename=log_file,
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)

def main():
    try:
        logging.info("Starting dummy keyring daemon (Bypass mode with 1-arg SearchItems)...")
        
        if 'DBUS_SESSION_BUS_ADDRESS' not in os.environ:
            logging.error("DBUS_SESSION_BUS_ADDRESS not found in environment.")
            sys.exit(1)
            
        connection = open_dbus_connection(bus='SESSION')
        logging.info("Connected and authenticated to D-Bus session bus.")
        
        bus = DBusAddress('/org/freedesktop/DBus',
                          bus_name='org.freedesktop.DBus',
                          interface='org.freedesktop.DBus')
                          
        req_msg = new_method_call(bus, 'RequestName', 'su',
                                  ('org.freedesktop.secrets', 4))
                                  
        reply = connection.send_and_get_reply(req_msg)
        logging.info(f"RequestName 'org.freedesktop.secrets' result: {reply}")
        
        # 15초 동안 요청이 없으면 자동 종료되는 안전장치 추가
        connection.sock.settimeout(15.0)
        
        while True:
            try:
                msg = connection.receive()
            except (socket.timeout, TimeoutError):
                logging.info("No activity for 15 seconds. Exiting dummy keyring daemon.")
                break
            except Exception as e:
                logging.error(f"Error receiving message: {e}")
                break
                
            if msg.header.message_type == MessageType.method_call:
                member = msg.header.fields.get(HeaderFields.member, 'Unknown')
                interface = msg.header.fields.get(HeaderFields.interface, 'Unknown')
                path = msg.header.fields.get(HeaderFields.path, 'Unknown')
                logging.info(f"Received method call: {member} on interface: {interface} (path: {path})")
                
                # OpenSession 메서드에 대해 성공 응답 반환
                if member == 'OpenSession' and interface == 'org.freedesktop.Secret.Service':
                    reply = new_method_return(
                        msg,
                        signature='vo',
                        body=(('s', ''), '/org/freedesktop/secrets/session/dummy')
                    )
                    connection.send(reply)
                    logging.info("Sent SUCCESS method return for OpenSession.")
                    continue
                
                # Collections 프로퍼티 조회에 대해 빈 리스트 반환
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
                
                # Unlock 메서드에 대해 입력받은 컬렉션 경로를 그대로 언락 성공 처리해 반환
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
                
                # SearchItems 메서드에 대해 성공 응답 반환 (빈 아이템 목록 - 1개 아웃풋 테스트)
                if member == 'SearchItems' and interface == 'org.freedesktop.Secret.Collection':
                    reply = new_method_return(
                        msg,
                        signature='ao',
                        body=([],)
                    )
                    connection.send(reply)
                    logging.info("Sent SUCCESS method return for SearchItems (1-arg version).")
                    continue
                
                # 그 외 모든 요청은 즉각 에러 반환 (NotSupported)
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
