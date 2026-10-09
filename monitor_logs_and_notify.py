
import os
import time
import requests
import yaml
from datetime import datetime

DOCKER_STACK_FILE = os.getenv('DOCKER_STACK_FILE', 'docker-stack.yml')
STATE_DIR = os.getenv('STATE_DIR', '/tmp/monitor_logs_state')
TELEGRAM_BOT_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN', '')
TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID', '')
CHECK_INTERVAL = int(os.getenv('CHECK_INTERVAL', '1200'))  # 20 minutos en segundos

# Servicio: ruta de log (relativa al host)
SERVICE_LOG_PATHS = {}

def ensure_state_dir():
    if not os.path.exists(STATE_DIR):
        os.makedirs(STATE_DIR, exist_ok=True)

def get_services_and_logs():
    """
    Lee el docker-stack.yml y extrae los servicios y sus rutas de logs si están bind-mount en ./logs/<servicio> o similar.
    """
    with open(DOCKER_STACK_FILE, 'r') as f:
        stack = yaml.safe_load(f)
    services = stack.get('services', {})
    service_logs = {}
    for svc, cfg in services.items():
        if 'volumes' in cfg:
            for v in cfg['volumes']:
                # Bind mounts pueden ser dict o string
                if isinstance(v, dict):
                    src = v.get('source', '')
                    tgt = v.get('target', '')
                else:
                    parts = v.split(':')
                    src = parts[0]
                    tgt = parts[1] if len(parts) > 1 else ''
                # Busca logs típicos
                if ('logs' in src or 'logs' in tgt) and (src.startswith('./logs/') or src.startswith('logs/')):
                    # El log real está en src, pero puede ser carpeta
                    service_logs[svc] = os.path.abspath(src)
    return service_logs

def notify_telegram(message):
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    data = {'chat_id': TELEGRAM_CHAT_ID, 'text': message}
    try:
        requests.post(url, data=data, timeout=10)
    except Exception as e:
        print(f"Error enviando a Telegram: {e}")

def get_last_exception_time(service):
    ensure_state_dir()
    state_file = os.path.join(STATE_DIR, f"{service}.txt")
    if os.path.exists(state_file):
        with open(state_file, 'r') as f:
            return f.read().strip()
    return ''

def save_last_exception_time(service, ts):
    ensure_state_dir()
    state_file = os.path.join(STATE_DIR, f"{service}.txt")
    with open(state_file, 'w') as f:
        f.write(ts)

def parse_log_time(line):
    # Ajusta el parseo según el formato de tu log
    try:
        # Ejemplo: 'May 29 10:23:45 ...'
        parts = line.split()
        if len(parts) >= 3:
            log_time = ' '.join(parts[:3])
            # Convierte a formato ISO para comparación
            dt = datetime.strptime(log_time, '%b %d %H:%M:%S')
            # Año actual
            dt = dt.replace(year=datetime.now().year)
            return dt.isoformat()
    except Exception:
        pass
    return datetime.now().isoformat()

def monitor_service_log(service, log_dir):
    # Busca archivos en el directorio de logs
    if not os.path.isdir(log_dir):
        return
    # Busca archivos .log o todos los archivos
    log_files = [os.path.join(log_dir, f) for f in os.listdir(log_dir) if f.endswith('.log') or os.path.isfile(os.path.join(log_dir, f))]
    for log_file in log_files:
        try:
            last_exception_time = get_last_exception_time(service)
            with open(log_file, 'r') as f:
                f.seek(0, 2)
                while True:
                    line = f.readline()
                    if not line:
                        break
                    if 'exception' in line.lower():
                        log_time = parse_log_time(line)
                        if log_time != last_exception_time:
                            msg = f"[{service}] Nueva excepción detectada a las {log_time}:\n{line.strip()}"
                            notify_telegram(msg)
                            save_last_exception_time(service, log_time)
                            last_exception_time = log_time
        except Exception as e:
            print(f"Error leyendo log de {service}: {e}")

def main():
    while True:
        service_logs = get_services_and_logs()
        for service, log_dir in service_logs.items():
            monitor_service_log(service, log_dir)
        time.sleep(CHECK_INTERVAL)

if __name__ == '__main__':
    main()


def notify_telegram(message):
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    data = {'chat_id': TELEGRAM_CHAT_ID, 'text': message}
    try:
        requests.post(url, data=data, timeout=10)
    except Exception as e:
        print(f"Error enviando a Telegram: {e}")

def get_last_exception_time():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE, 'r') as f:
            return f.read().strip()
    return ''

def save_last_exception_time(ts):
    with open(STATE_FILE, 'w') as f:
        f.write(ts)

def parse_log_time(line):
    # Ajusta el parseo según el formato de tu log
    try:
        # Ejemplo: 'May 29 10:23:45 ...'
        parts = line.split()
        if len(parts) >= 3:
            log_time = ' '.join(parts[:3])
            # Convierte a formato ISO para comparación
            dt = datetime.strptime(log_time, '%b %d %H:%M:%S')
            # Año actual
            dt = dt.replace(year=datetime.now().year)
            return dt.isoformat()
    except Exception:
        pass
    return datetime.now().isoformat()

def main():
    last_exception_time = get_last_exception_time()
    with open(LOG_FILE, 'r') as f:
        # Ir al final del archivo
        f.seek(0, 2)
        while True:
            line = f.readline()
            if not line:
                time.sleep(CHECK_INTERVAL)
                continue
            if 'exception' in line.lower():
                log_time = parse_log_time(line)
                if log_time != last_exception_time:
                    msg = f"[{SERVICE_NAME}] Nueva excepción detectada a las {log_time}:\n{line.strip()}"
                    notify_telegram(msg)
                    save_last_exception_time(log_time)
                    last_exception_time = log_time

if __name__ == '__main__':
    main()
