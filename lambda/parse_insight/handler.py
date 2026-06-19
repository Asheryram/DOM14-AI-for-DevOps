import json
import sys


def human_range(r):
    return f"{r.get('StartTime', 'N/A')} -> {r.get('EndTime', 'N/A')}"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'insight_export.json'
    with open(path) as f:
        data = json.load(f)

    insights = data.get('Insights', []) if isinstance(data, dict) else data
    for it in insights:
        print('InsightId:        ', it.get('InsightId'))
        print('Name:             ', it.get('Name'))
        print('Severity:         ', it.get('Severity'))
        print('Status:           ', it.get('Status'))
        print('AnomalyTimeRange: ', human_range(it.get('AnomalyTimeRange', {})))
        top = it.get('TopAnomaly', {})
        print('Top metric:       ', top.get('MetricName'), '  deviation:', top.get('Deviation'))
        print('---')


if __name__ == '__main__':
    main()
