import requests
from datetime import datetime

def check_http_endpoint(url: str) -> dict:
    """
    Check if an HTTP endpoint is healthy.
    Returns dict with status, response_time, error if any.
    """
    try:
        start = datetime.now()
        response = requests.get(url, timeout=10)
        response_time = (datetime.now() - start).total_seconds() * 1000  # ms
        if response.status_code == 200:
            return {"status": "healthy", "response_time": response_time}
        else:
            return {"status": "unhealthy", "response_time": response_time, "error": f"Status {response.status_code}"}
    except Exception as e:
        return {"status": "unhealthy", "error": str(e)}

def monitor_endpoints(endpoints: list) -> list:
    """
    Monitor a list of endpoints.
    Returns list of incidents if any are unhealthy.
    """
    incidents = []
    for url in endpoints:
        result = check_http_endpoint(url)
        if result["status"] != "healthy":
            incidents.append({
                "type": "HTTP Endpoint Down",
                "details": f"Endpoint {url} is {result['status']}: {result.get('error', '')}",
                "severity": "HIGH",
                "timestamp": datetime.now()
            })
    return incidents