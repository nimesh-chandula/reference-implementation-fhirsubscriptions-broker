// URL encoding and decoding utilities

// URL encode a string value
public function urlEncode(string value) returns string {
    string result = value;
    string:RegExp percentPattern = re `%`;
    result = percentPattern.replaceAll(result, "%25");
    string:RegExp spacePattern = re ` `;
    result = spacePattern.replaceAll(result, "%20");
    string:RegExp colonPattern = re `:`;
    result = colonPattern.replaceAll(result, "%3A");
    string:RegExp slashPattern = re `/`;
    result = slashPattern.replaceAll(result, "%2F");
    string:RegExp questionPattern = re `\?`;
    result = questionPattern.replaceAll(result, "%3F");
    string:RegExp ampersandPattern = re `&`;
    result = ampersandPattern.replaceAll(result, "%26");
    string:RegExp equalsPattern = re `=`;
    result = equalsPattern.replaceAll(result, "%3D");
    return result;
}

// URL decode a component (handles %XX encoding)
public function decodeUrlComponent(string encoded) returns string {
    string result = encoded;

    string:RegExp plusPattern = re `\+`;
    result = plusPattern.replaceAll(result, " ");

    string:RegExp p20 = re `%20`;
    result = p20.replaceAll(result, " ");
    string:RegExp p22 = re `%22`;
    result = p22.replaceAll(result, "\"");
    string:RegExp p7B = re `%7B`;
    result = p7B.replaceAll(result, "{");
    string:RegExp p7D = re `%7D`;
    result = p7D.replaceAll(result, "}");
    string:RegExp p5B = re `%5B`;
    result = p5B.replaceAll(result, "[");
    string:RegExp p5D = re `%5D`;
    result = p5D.replaceAll(result, "]");
    string:RegExp p3A = re `%3A`;
    result = p3A.replaceAll(result, ":");
    string:RegExp p2C = re `%2C`;
    result = p2C.replaceAll(result, ",");
    string:RegExp p2F = re `%2F`;
    result = p2F.replaceAll(result, "/");
    string:RegExp p3D = re `%3D`;
    result = p3D.replaceAll(result, "=");
    string:RegExp p26 = re `%26`;
    result = p26.replaceAll(result, "&");
    string:RegExp p2B = re `%2B`;
    result = p2B.replaceAll(result, "+");

    return result;
}

// Extract form parameter from URL-encoded body
public function extractFormParameter(string formData, string paramName) returns string? {
    string:RegExp ampersandPattern = re `&`;
    string[] pairs = ampersandPattern.split(formData);
    foreach string pair in pairs {
        string:RegExp equalsPattern = re `=`;
        string[] keyValue = equalsPattern.split(pair);
        if keyValue.length() == 2 && keyValue[0] == paramName {
            return keyValue[1];
        }
    }
    return ();
}
