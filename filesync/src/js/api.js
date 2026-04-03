    // ===== API =====
    async function api(method, url, body) {
        var opts = { method: method };
        if (body instanceof FormData) {
            opts.body = body;
        } else if (body) {
            opts.headers = { 'Content-Type': 'application/json' };
            opts.body = JSON.stringify(body);
        }
        var res = await fetch(url, opts);
        var text = await res.text();
        var data;
        try {
            data = JSON.parse(text);
        } catch (e) {
            throw new Error(res.ok ? 'Invalid server response' : 'Server error (' + res.status + ')');
        }
        if (!res.ok || data.error) {
            throw new Error(data.error || 'Request failed (' + res.status + ')');
        }
        return data;
    }
