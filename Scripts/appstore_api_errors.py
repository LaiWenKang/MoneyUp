"""Shared sanitized error type for CLI and imported App Store helpers."""


class AppStoreAPIError(RuntimeError):
    def __init__(self, status, method, endpoint, codes, agreement):
        self.status = status
        super().__init__(f"App Store HTTP {status} during {method} {endpoint}; codes={codes}; agreement_related={agreement}")
