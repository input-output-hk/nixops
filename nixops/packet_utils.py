# -*- coding: utf-8 -*-

import packet

def connect(api_token):
    return packet.Manager(auth_token=api_token)
