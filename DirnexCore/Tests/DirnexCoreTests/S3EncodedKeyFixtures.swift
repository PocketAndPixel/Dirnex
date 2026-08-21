import Foundation

/// The bytes a listing sends when a key **needs encoding** — a space, a non-ASCII name, a literal
/// `+` — and the stat pages that go with them.
///
/// Their own enum because they answer a question ``S3Fixtures`` structurally cannot: every page in
/// it carries `<EncodingType>url</EncodingType>` and not one of its keys has a character the
/// encoding touches, so the whole corpus is blind to what the wire spelling does. That is the
/// disjoint-corpus trap this backend has now been caught by twice (docs/NOTES.md ▸ curl for S3), and
/// keeping these together is what makes the gap visible rather than scattered through a file whose
/// name suggests it is already covered.
enum S3EncodedKeyFixtures {
    /// How a folder whose **name has a space** answers a stat — the shape in the 2026-08-22 report.
    ///
    /// The prefix and the common prefix both come back form-encoded, which is what makes this a
    /// fixture rather than a copy of ``statDocsFolder`` with a different word in it.
    static let statSpacedFolder = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>amzn-s3-df</Name>\
    <Prefix>untitled+folder</Prefix><KeyCount>1</KeyCount><MaxKeys>1000</MaxKeys>\
    <Delimiter>/</Delimiter><EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>\
    <CommonPrefixes><Prefix>untitled+folder/</Prefix></CommonPrefixes></ListBucketResult>
    """

    /// The **delete sweep** of that folder: `recursivePage`'s shape over keys that actually need
    /// decoding — a space, a nested folder with one, and a non-ASCII name.
    ///
    /// `recursivePage` cannot see the bug this pins even though it carries `<EncodingType>url</…>`,
    /// because not one of its keys has a character the encoding touches. Same disjoint-corpus trap
    /// the 2026-08-18 whitespace bug turned on (docs/NOTES.md ▸ curl for S3).
    static let spacedFolderSweep = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>amzn-s3-df</Name>\
    <Prefix>untitled+folder/</Prefix><KeyCount>3</KeyCount><MaxKeys>1000</MaxKeys>\
    <EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>\
    <Contents><Key>untitled+folder/</Key><LastModified>2026-08-20T10:00:00.000Z</LastModified>\
    <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag><Size>0</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>untitled+folder/%D1%84%D0%B0%D0%B9%D0%BB.txt</Key>\
    <LastModified>2026-08-20T10:00:00.000Z</LastModified>\
    <ETag>&quot;6d1792d429159aabb630926c37254766&quot;</ETag><Size>12</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>untitled+folder/sub+dir/DSC_0004.NEF</Key>\
    <LastModified>2026-08-20T10:00:00.000Z</LastModified>\
    <ETag>&quot;6d1792d429159aabb630926c37254767&quot;</ETag><Size>34</Size>\
    <StorageClass>STANDARD</StorageClass></Contents></ListBucketResult>
    """

    /// The same sweep from an endpoint that **ignores** `encoding-type` and never echoes it, over a
    /// key holding a literal `+`. The identical bytes mean the opposite thing here, and only the
    /// echo says which — so this is the control that keeps the decode from being applied blind.
    static let plusKeySweepUndeclared = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>amzn-s3-df</Name>\
    <Prefix>a+b/</Prefix><KeyCount>2</KeyCount><MaxKeys>1000</MaxKeys>\
    <IsTruncated>false</IsTruncated>\
    <Contents><Key>a+b/</Key><LastModified>2026-08-20T10:00:00.000Z</LastModified>\
    <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag><Size>0</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>a+b/plus+file.txt</Key><LastModified>2026-08-20T10:00:00.000Z</LastModified>\
    <ETag>&quot;6d1792d429159aabb630926c37254766&quot;</ETag><Size>1</Size>\
    <StorageClass>STANDARD</StorageClass></Contents></ListBucketResult>
    """

    /// Its stat, likewise undeclared.
    static let statPlusFolderUndeclared = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>amzn-s3-df</Name>\
    <Prefix>a+b</Prefix><KeyCount>1</KeyCount><MaxKeys>1000</MaxKeys><Delimiter>/</Delimiter>\
    <IsTruncated>false</IsTruncated><CommonPrefixes><Prefix>a+b/</Prefix></CommonPrefixes>\
    </ListBucketResult>
    """

    /// A sweep carrying a key whose percent-encoding is **invalid**, so nothing can name it.
    ///
    /// A listing is right to drop such a row; a delete that drops it reports a folder as gone with a
    /// file still under it, which is why the two routes answer differently.
    static let undecodableKeySweep = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>amzn-s3-df</Name>\
    <Prefix>docs/</Prefix><KeyCount>2</KeyCount><MaxKeys>1000</MaxKeys>\
    <EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>\
    <Contents><Key>docs/</Key><LastModified>2026-08-20T10:00:00.000Z</LastModified>\
    <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag><Size>0</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>docs/broken%ZZ.txt</Key><LastModified>2026-08-20T10:00:00.000Z</LastModified>\
    <ETag>&quot;6d1792d429159aabb630926c37254766&quot;</ETag><Size>1</Size>\
    <StorageClass>STANDARD</StorageClass></Contents></ListBucketResult>
    """
}
