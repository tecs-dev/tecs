<?xml version="1.0" encoding="UTF-8"?>
<tileset version="1.10" tiledversion="1.11.0" name="terrain" tilewidth="16" tileheight="16" tilecount="2" columns="2">
 <image source="tiles.png" width="32" height="16"/>
 <tile id="0" class="grass"><properties><property name="cost" type="int" value="2"/></properties><animation><frame tileid="0" duration="100"/><frame tileid="1" duration="100"/></animation></tile>
 <tile id="1" class="wall"><objectgroup><object id="1" x="0" y="0" width="16" height="16"/></objectgroup></tile>
</tileset>
